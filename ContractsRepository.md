

# Переписанный `ContractsRepository`

```java
@Service
@Slf4j
public class ContractsRepository implements SaveRepositoryStrategy {

    private final JdbcTemplate jdbcTemplate;

    public ContractsRepository(JdbcTemplate jdbcTemplate) {
        this.jdbcTemplate = jdbcTemplate;
    }

    // ========== Статический SQL для MERGE с UNNEST (парсится БД один раз) ==========
    private static final String MERGE_SQL = """
            WITH src_from_app AS (
                SELECT * FROM UNNEST(
                    ?::bigint[], ?::varchar[], ?::bigint[], ?::int[], ?::int[], ?::varchar[]
                ) AS appTable(id, object_class, global_id, revision, version, token)
            ),
            
            records_lock_check AS (
                SELECT CASE
                    WHEN NOT EXISTS (
                        SELECT sfa.*, mol.* FROM src_from_app AS sfa
                        LEFT JOIN murex.object_lock mol
                            ON mol.token = sfa.token
                            AND expire >= NOW()
                            AND sfa.global_id = mol.global_id
                        WHERE mol.token IS NULL
                    )
                    THEN 'YES'
                    ELSE 'NO'
                END AS all_records_have_lock
            ),
            
            src_from_table AS (
                SELECT mcm.*, sfa.token
                FROM murex.contract_main AS mcm
                JOIN src_from_app AS sfa
                    ON mcm.global_id = sfa.global_id
                WHERE closed_at = TIMESTAMP '3000-01-01 00:00:00'
            ),
            
            total_data AS (
                SELECT * FROM src_from_table
                UNION ALL
                SELECT id, object_class, global_id, revision, version, null, null, token
                FROM src_from_app
            ),
            
            data_for_merge AS (
                SELECT * FROM total_data td
                CROSS JOIN records_lock_check rlc
                WHERE rlc.all_records_have_lock != 'NO'
            )
            
            MERGE INTO murex.contract_main AS mcm
            USING data_for_merge AS dfm
            ON mcm.id = dfm.id
            WHEN MATCHED THEN
                UPDATE SET closed_at = NOW()
            WHEN NOT MATCHED THEN
                INSERT (id, object_class, global_id, revision, version, saved_at, closed_at)
                VALUES (dfm.id, dfm.object_class, dfm.global_id, dfm.revision, dfm.version,
                        NOW(), TIMESTAMP '3000-01-01 00:00:00');
            """;

    // ========== Статические SQL для простых INSERT ==========
    private static final String INSERT_INDEX_SQL =
            "INSERT INTO contract_index (id, number, created_at) VALUES (?, ?, now())";

    private static final String COPY_DATA_SQL =
            "COPY contract_data (id, content, created_at) FROM STDIN WITH (FORMAT csv, DELIMITER E'\\t')";

    @Override
    public int save(List<ObjectRequest> contracts) throws JsonProcessingException {
        if (contracts.isEmpty()) {
            return 0;
        }

        // ===== Шаг 1: Подготовка массивов для UNNEST =====
        int size = contracts.size();
        Long[] ids = new Long[size];
        String[] objectClasses = new String[size];
        Long[] globalIds = new Long[size];
        Integer[] revisions = new Integer[size];
        Integer[] versions = new Integer[size];
        String[] tokens = new String[size];

        for (int i = 0; i < size; i++) {
            var obj = contracts.get(i);
            var data = (ContractsObjectRequest) obj.getData();
            ids[i] = obj.getHeader().getId();
            objectClasses[i] = data.getObjectType();
            globalIds[i] = obj.getHeader().getGlobalId();
            revisions[i] = obj.getHeader().getRevision() != null
                    ? obj.getHeader().getRevision() : data.getRevision();
            versions[i] = obj.getHeader().getVersion() != null
                    ? obj.getHeader().getVersion() : data.getVersion();
            tokens[i] = obj.getHeader().getLockId();
        }

        // ===== Шаг 2: Выполняем MERGE через UNNEST (статический SQL) =====
        int mergeResult = jdbcTemplate.execute((ConnectionCallback<Integer>) con -> {
            try (PreparedStatement ps = con.prepareStatement(MERGE_SQL)) {
                ps.setArray(1, con.createArrayOf("bigint", ids));
                ps.setArray(2, con.createArrayOf("varchar", objectClasses));
                ps.setArray(3, con.createArrayOf("bigint", globalIds));
                ps.setArray(4, con.createArrayOf("integer", revisions));
                ps.setArray(5, con.createArrayOf("integer", versions));
                ps.setArray(6, con.createArrayOf("varchar", tokens));
                return ps.executeUpdate();
            }
        });

        if (mergeResult == 0) {
            return 0;
        }

        // ===== Шаг 3: INSERT в contract_index через batchUpdate =====
        jdbcTemplate.batchUpdate(INSERT_INDEX_SQL, new BatchPreparedStatementSetter() {
            @Override
            public void setValues(PreparedStatement ps, int i) throws SQLException {
                var obj = contracts.get(i);
                var data = (ContractsObjectRequest) obj.getData();
                ps.setLong(1, obj.getHeader().getId());
                ps.setString(2, data.getNumber());
            }

            @Override
            public int getBatchSize() {
                return contracts.size();
            }
        });

        // ===== Шаг 4: COPY для contract_data (JSONB — тяжёлые данные) =====
        jdbcTemplate.execute((ConnectionCallback<Void>) con -> {
            PGConnection pgCon = con.unwrap(PGConnection.class);
            CopyManager copyManager = pgCon.getCopyAPI();

            // Формируем поток данных в формате: id\tcontent\ttimestamp
            StringBuilder copyBuffer = new StringBuilder(size * 512);
            String now = java.time.LocalDateTime.now()
                    .format(java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss"));

            for (ObjectRequest obj : contracts) {
                long id = obj.getHeader().getId();
                // Экранируем JSON для CSV: оборачиваем в кавычки, удваиваем внутренние кавычки
                String json = obj.getJsonBody();
                String escapedJson = "\"" + json.replace("\"", "\"\"") + "\"";

                copyBuffer.append(id)
                        .append('\t')
                        .append(escapedJson)
                        .append('\t')
                        .append(now)
                        .append('\n');
            }

            byte[] bytes = copyBuffer.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8);
            copyManager.copyIn(COPY_DATA_SQL, new java.io.ByteArrayInputStream(bytes));
            return null;
        });

        return mergeResult;
    }
}
```

## Что изменилось и почему

### MERGE — `UNNEST` вместо динамического `VALUES`

| Было | Стало |
|------|-------|
| Каждый батч — **уникальная** SQL-строка с N×6 плейсхолдерами | **Одна статическая** SQL-строка, план кэшируется |
| PostgreSQL парсит и планирует заново каждый раз | План строится **один раз**, переиспользуется |
| Тысячи `params.add()` → массив `Object[]` | 6 массивов → 6 вызовов `setArray` |

### `contract_index` — `batchUpdate`

| Было | Стало |
|------|-------|
| Динамическая склейка `VALUES (...), (...)` | `jdbcTemplate.batchUpdate` с `BatchPreparedStatementSetter` |
| Новый план на каждый размер батча | Один `PreparedStatement`, переиспользуется |

> **Важно:** в `application.yml` (или в URL подключения) добавьте:
> ```
> jdbc:postgresql://host:port/db?reWriteBatchedInserts=true
> ```
> Это заставит драйвер автоматически склеивать батч в эффективный multi-row INSERT.

### `contract_data` — `COPY` вместо `INSERT`

| Было | Стало |
|------|-------|
| Динамический INSERT с `?::jsonb` — БД парсит JSON + планирует запрос | `COPY FROM STDIN` — потоковая загрузка, **без планирования** |
| Каждый JSON проходит через JDBC parameter binding | Данные идут бинарным потоком напрямую |

`COPY` — это самый быстрый способ загрузки данных в PostgreSQL. Для таблицы `contract_data`, где только `id + jsonb + timestamp`, это идеальный выбор.

### Необходимые импорты

```java
import org.postgresql.PGConnection;
import org.postgresql.copy.CopyManager;
import org.springframework.jdbc.core.BatchPreparedStatementSetter;
import org.springframework.jdbc.core.ConnectionCallback;
import org.springframework.jdbc.core.JdbcTemplate;

import java.sql.PreparedStatement;
import java.sql.SQLException;
import java.nio.charset.StandardCharsets;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
```

### Зависимость в `pom.xml` (если ещё нет)

```xml
<dependency>
    <groupId>org.postgresql</groupId>
    <artifactId>postgresql</artifactId>
    <version>42.7.4</version>
</dependency>
```
