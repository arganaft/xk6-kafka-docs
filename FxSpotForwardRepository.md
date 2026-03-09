

# Переписанный `FxSpotForwardRepository`

Вот полностью переработанный класс с применением всех рекомендованных оптимизаций:

```java
@Service
@Slf4j
public class FxSpotForwardRepository implements SaveRepositoryStrategy {

    private final JdbcTemplate jdbcTemplate;

    public FxSpotForwardRepository(JdbcTemplate jdbcTemplate) {
        this.jdbcTemplate = jdbcTemplate;
    }

    @Override
    public int save(List<ObjectRequest> request) throws JsonProcessingException {

        // ===== Шаг 1: Подготовка массивов для UNNEST =====
        int size = request.size();

        Long[] ids = new Long[size];
        String[] objectClasses = new String[size];
        Long[] globalIds = new Long[size];
        java.sql.Date[] actualFroms = new java.sql.Date[size];
        Boolean[] draftStatuses = new Boolean[size];
        Integer[] revisions = new Integer[size];
        Integer[] versions = new Integer[size];
        String[] tokens = new String[size];

        // Массивы для fx_spot_forward_index
        Long[] indexIds = new Long[size];
        BigDecimal[] notionalAmounts = new BigDecimal[size];
        String[] notionalCurrencies = new String[size];

        // Массивы для trade_index
        Long[] tradeIndexIds = new Long[size];
        Long[] legalEntityIds = new Long[size];
        Long[] portfolioIds = new Long[size];
        Long[] contractIds = new Long[size];

        for (int i = 0; i < size; i++) {
            var obj = request.get(i);
            var header = obj.getHeader();
            var data = (FxSpotForwardObjectRequest) obj.getData();

            ids[i] = header.getId();
            objectClasses[i] = data.getObjectType();
            globalIds[i] = header.getGlobalId();
            actualFroms[i] = java.sql.Date.valueOf(LocalDate.parse(header.getActualFrom()));
            draftStatuses[i] = header.getDraftStatus().equals("DRAFT");
            revisions[i] = header.getRevision();
            versions[i] = header.getVersion();
            tokens[i] = header.getLockId();

            indexIds[i] = header.getId();
            notionalAmounts[i] = data.getNotionalAmount();
            notionalCurrencies[i] = data.getNotionalCurrencyId().toString();

            tradeIndexIds[i] = header.getId();
            legalEntityIds[i] = data.getLegalEntityId();
            portfolioIds[i] = data.getPortfolioId();
            contractIds[i] = data.getContractId();
        }

        // ===== Шаг 2: Основной CTE-запрос с UNNEST (статический SQL) =====
        String mainSql = """
                WITH src_from_app AS (
                    SELECT *
                    FROM UNNEST(
                        ?::bigint[],
                        ?::varchar[],
                        ?::bigint[],
                        ?::date[],
                        ?::bool[],
                        ?::int[],
                        ?::int[],
                        ?::varchar[]
                    ) AS app_table(id, object_class, global_id, actual_from, draft_status, revision, version, token)
                ),
                const AS (
                    SELECT
                        NOW()::TIMESTAMP                AS ts_now,
                        DATE '3000-01-01'               AS biz_inf,
                        TIMESTAMP '3000-01-01 00:00:00' AS tech_inf
                ),
                lock_check AS (
                    SELECT NOT EXISTS (
                        SELECT 1
                        FROM src_from_app s
                        LEFT JOIN murex.object_lock l
                            ON l.token = s.token
                           AND l.expire >= NOW()
                        WHERE l.token IS NULL
                    ) AS all_records_have_lock
                ),
                active_seg AS (
                    SELECT
                        s.*,
                        seg.actual_from AS seg_from,
                        seg.actual_to   AS seg_to
                    FROM src_from_app s
                    LEFT JOIN LATERAL (
                        SELECT tm.actual_from, tm.actual_to
                        FROM trade_main tm
                        CROSS JOIN const c
                        WHERE tm.object_class = s.object_class
                          AND tm.global_id = s.global_id
                          AND tm.closed_at = c.tech_inf
                          AND s.actual_from >= tm.actual_from
                          AND s.actual_from < tm.actual_to
                        ORDER BY tm.actual_from DESC
                        LIMIT 1
                        FOR UPDATE OF tm
                    ) seg ON TRUE
                ),
                src_norm AS (
                    SELECT
                        a.id, a.object_class, a.global_id,
                        a.actual_from,
                        c.biz_inf AS actual_to,
                        a.draft_status,
                        a.revision,
                        CASE WHEN a.draft_status = false THEN a.version ELSE NULL END AS version,
                        a.seg_from, a.seg_to,
                        a.token
                    FROM active_seg a
                    CROSS JOIN const c
                ),
                cut_business_period AS (
                    UPDATE trade_main tm
                    SET actual_to = s.actual_from
                    FROM src_norm s
                    CROSS JOIN const c
                    JOIN lock_check lc ON lc.all_records_have_lock
                    WHERE s.seg_from IS NOT NULL
                      AND s.actual_from > s.seg_from
                      AND tm.object_class = s.object_class
                      AND tm.global_id = s.global_id
                      AND tm.closed_at = c.tech_inf
                      AND tm.actual_from = s.seg_from
                      AND tm.actual_to = s.seg_to
                      AND s.draft_status = false
                      AND tm.draft_status = false
                ),
                close_technical AS (
                    UPDATE trade_main tm
                    SET closed_at = c.ts_now
                    FROM src_norm s
                    CROSS JOIN const c
                    JOIN lock_check lc ON lc.all_records_have_lock
                    WHERE tm.object_class = s.object_class
                      AND tm.global_id = s.global_id
                      AND tm.closed_at = c.tech_inf
                      AND (
                          (s.draft_status = true AND tm.draft_status = true)
                          OR
                          (s.draft_status = false AND (
                              tm.draft_status = true
                              OR (
                                  tm.draft_status = false
                                  AND s.seg_from IS NOT NULL
                                  AND tm.actual_from = s.seg_from
                                  AND tm.actual_to = CASE
                                                        WHEN s.actual_from > s.seg_from THEN s.actual_from
                                                        ELSE s.seg_to
                                                     END
                              )
                          ))
                      )
                ),
                ins AS (
                    INSERT INTO trade_main (
                        id, object_class, global_id,
                        actual_from, actual_to,
                        draft_status,
                        revision, version,
                        saved_at, closed_at
                    )
                    SELECT
                        s.id, s.object_class, s.global_id,
                        s.actual_from, s.actual_to,
                        s.draft_status,
                        s.revision, s.version,
                        c.ts_now, c.tech_inf
                    FROM src_norm s
                    CROSS JOIN const c
                    JOIN lock_check lc ON lc.all_records_have_lock
                    RETURNING id
                )
                SELECT COUNT(*) FROM ins
                """;

        Integer insertedRows;
        try {
            insertedRows = jdbcTemplate.execute((ConnectionCallback<Integer>) con -> {
                try (PreparedStatement ps = con.prepareStatement(mainSql)) {
                    ps.setArray(1, con.createArrayOf("bigint", ids));
                    ps.setArray(2, con.createArrayOf("varchar", objectClasses));
                    ps.setArray(3, con.createArrayOf("bigint", globalIds));
                    ps.setArray(4, con.createArrayOf("date", actualFroms));
                    ps.setArray(5, con.createArrayOf("boolean", draftStatuses));
                    ps.setArray(6, con.createArrayOf("integer", revisions));
                    ps.setArray(7, con.createArrayOf("integer", versions));
                    ps.setArray(8, con.createArrayOf("varchar", tokens));

                    try (var rs = ps.executeQuery()) {
                        return rs.next() ? rs.getInt(1) : 0;
                    }
                }
            });
        } catch (Exception e) {
            log.error("Failed to execute main upsert query", e);
            throw e;
        }

        if (insertedRows == 0) {
            log.warn("No rows were inserted into trade_main. "
                    + "Check lock_check, active_seg, or duplicate periods.");
            return 0;
        }

        // ===== Шаг 3: COPY для fx_spot_forward_data (JSONB — тяжёлые данные) =====
        copyFxSpotForwardData(request);

        // ===== Шаг 4: batchUpdate для fx_spot_forward_index =====
        batchInsertFxSpotForwardIndex(request);

        // ===== Шаг 5: batchUpdate для trade_index =====
        batchInsertTradeIndex(request);

        return insertedRows;
    }

    /**
     * COPY для fx_spot_forward_data — максимально быстрая вставка JSONB.
     * Используем PgConnection.getCopyAPI() напрямую.
     */
    private void copyFxSpotForwardData(List<ObjectRequest> request) {
        String copySql = "COPY fx_spot_forward_data (id, content, created_at) FROM STDIN WITH (FORMAT csv, DELIMITER E'\\t', QUOTE E'\\x01')";

        jdbcTemplate.execute((ConnectionCallback<Void>) con -> {
            // Разворачиваем HikariCP proxy до настоящего PgConnection
            PGConnection pgConn = con.unwrap(PGConnection.class);
            CopyManager copyManager = pgConn.getCopyAPI();

            Timestamp now = Timestamp.valueOf(LocalDateTime.now());

            StringBuilder buffer = new StringBuilder(request.size() * 512);
            for (ObjectRequest obj : request) {
                // id
                buffer.append(obj.getHeader().getId());
                buffer.append('\t');
                // content (jsonb) — оборачиваем в QUOTE-символ \x01,
                // чтобы табы и переносы внутри JSON не ломали формат
                buffer.append('\u0001');
                buffer.append(obj.getJsonBody());
                buffer.append('\u0001');
                buffer.append('\t');
                // created_at
                buffer.append(now.toString());
                buffer.append('\n');
            }

            byte[] bytes = buffer.toString().getBytes(StandardCharsets.UTF_8);
            copyManager.copyIn(copySql, new ByteArrayInputStream(bytes));

            return null;
        });
    }

    /**
     * batchUpdate для fx_spot_forward_index.
     * С reWriteBatchedInserts=true в URL драйвер склеит это в эффективный multi-row INSERT.
     */
    private void batchInsertFxSpotForwardIndex(List<ObjectRequest> request) {
        String sql = "INSERT INTO fx_spot_forward_index (id, national_amount, national_currency, created_at) "
                + "VALUES (?, ?, ?, now())";

        jdbcTemplate.batchUpdate(sql, new BatchPreparedStatementSetter() {
            @Override
            public void setValues(PreparedStatement ps, int i) throws SQLException {
                var obj = request.get(i);
                var data = (FxSpotForwardObjectRequest) obj.getData();
                ps.setLong(1, obj.getHeader().getId());
                ps.setBigDecimal(2, data.getNotionalAmount());
                ps.setString(3, data.getNotionalCurrencyId().toString());
            }

            @Override
            public int getBatchSize() {
                return request.size();
            }
        });
    }

    /**
     * batchUpdate для trade_index.
     */
    private void batchInsertTradeIndex(List<ObjectRequest> request) {
        String sql = "INSERT INTO trade_index (id, legal_entity_id, portfolio_id, contract_id, created_at) "
                + "VALUES (?, ?, ?, ?, now())";

        jdbcTemplate.batchUpdate(sql, new BatchPreparedStatementSetter() {
            @Override
            public void setValues(PreparedStatement ps, int i) throws SQLException {
                var obj = request.get(i);
                var data = (FxSpotForwardObjectRequest) obj.getData();
                ps.setLong(1, obj.getHeader().getId());
                ps.setLong(2, data.getLegalEntityId());
                ps.setLong(3, data.getPortfolioId());
                ps.setLong(4, data.getContractId());
            }

            @Override
            public int getBatchSize() {
                return request.size();
            }
        });
    }
}
```

## Необходимые импорты

```java
import org.postgresql.PGConnection;
import org.postgresql.copy.CopyManager;

import java.io.ByteArrayInputStream;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.sql.PreparedStatement;
import java.sql.Timestamp;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.util.List;
```

## Обязательные настройки `application.yml`

```yaml
spring:
  datasource:
    # reWriteBatchedInserts — ключевой параметр для batchUpdate!
    url: jdbc:postgresql://host:port/db?reWriteBatchedInserts=true
    hikari:
      maximum-pool-size: 20
      minimum-idle: 5
```

## Что изменилось и почему это быстрее

| Что было | Что стало | Эффект |
|---|---|---|
| `StringBuilder` + тысячи `?` плейсхолдеров в CTE | **Статический SQL + `UNNEST` из массивов** | PostgreSQL парсит и кэширует план **один раз**; передача 8 массивов вместо `8 × N` параметров |
| Один гигантский SQL с тремя `INSERT` через `;` и склеенными `VALUES` | **`COPY` для JSONB** + **`batchUpdate`** для index-таблиц | COPY обходит весь SQL-парсер PostgreSQL; `batchUpdate` + `reWriteBatchedInserts` склеивается драйвером в оптимальный multi-row INSERT без ручной конкатенации |
| `ObjectMapper` создавался в каждом вызове (но не использовался) | Удалён | Убран мусор |
| JSON передавался как `?::jsonb` строковый параметр | **COPY binary stream** | Нет overhead на биндинг тысяч параметров; данные идут потоком напрямую в таблицу |
