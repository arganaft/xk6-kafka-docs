

# Переписанный `CashflowRepository`

Я разделю сохранение на три таблицы, применив разные стратегии согласно советам:

- **`cashflow_main`** и **`cashflow_index`** — через `UNNEST` (массивы PostgreSQL, один статический SQL)
- **`cashflow_data`** — через `COPY` (для больших JSONB-данных это самый быстрый путь)

```java
@Service
@Slf4j
public class CashflowRepository implements SaveRepositoryStrategy {

    private final JdbcTemplate jdbcTemplate;

    public CashflowRepository(JdbcTemplate jdbcTemplate) {
        this.jdbcTemplate = jdbcTemplate;
    }

    @Override
    public int save(List<ObjectRequest> request) throws JsonProcessingException {
        if (request == null || request.isEmpty()) {
            return 0;
        }

        int size = request.size();

        // ========== 1. Подготовка массивов для всех трёх таблиц ==========

        // cashflow_main
        Long[] mainIds = new Long[size];
        String[] objectClasses = new String[size];
        Long[] parentIds = new Long[size];

        // cashflow_data
        Long[] dataIds = new Long[size];
        String[] jsonBodies = new String[size];

        // cashflow_index
        Long[] indexIds = new Long[size];
        java.sql.Date[] paymentDates = new java.sql.Date[size];
        BigDecimal[] paymentAmounts = new BigDecimal[size];
        String[] paymentCurrencies = new String[size];

        for (int i = 0; i < size; i++) {
            ObjectRequest obj = request.get(i);
            CashflowObjectRequest data = (CashflowObjectRequest) obj.getData();

            // cashflow_main
            mainIds[i] = obj.getHeader().getId();
            objectClasses[i] = data.getObjectType();
            parentIds[i] = obj.getHeader().getParentId();

            // cashflow_data
            dataIds[i] = obj.getHeader().getId();
            jsonBodies[i] = obj.getJsonBody();

            // cashflow_index
            indexIds[i] = obj.getHeader().getId();
            paymentDates[i] = java.sql.Date.valueOf(LocalDate.parse(data.getPaymentDate()));
            paymentAmounts[i] = data.getPaymentAmount();
            paymentCurrencies[i] = data.getPaymentCurrencyId().toString();
        }

        // ========== 2. Вставка через UNNEST — один статический SQL ==========

        return jdbcTemplate.execute((ConnectionCallback<Integer>) con -> {

            // --- cashflow_main через UNNEST ---
            saveCashflowMain(con, mainIds, objectClasses, parentIds);

            // --- cashflow_data через COPY ---
            saveCashflowDataViaCopy(con, dataIds, jsonBodies);

            // --- cashflow_index через UNNEST ---
            saveCashflowIndex(con, indexIds, paymentDates, paymentAmounts, paymentCurrencies);

            return size;
        });
    }

    /**
     * cashflow_main — статический SQL + UNNEST (массивы).
     * План запроса кэшируется PostgreSQL, парсинг происходит один раз.
     */
    private void saveCashflowMain(Connection con,
                                  Long[] ids,
                                  String[] objectClasses,
                                  Long[] parentIds) throws SQLException {

        String sql = """
                INSERT INTO cashflow_main (id, object_class, parent_id, created_at)
                SELECT u.id, u.object_class, u.parent_id, now()
                FROM UNNEST(?::bigint[], ?::varchar[], ?::bigint[])
                    AS u(id, object_class, parent_id)
                """;

        try (PreparedStatement ps = con.prepareStatement(sql)) {
            ps.setArray(1, con.createArrayOf("bigint", ids));
            ps.setArray(2, con.createArrayOf("varchar", objectClasses));
            ps.setArray(3, con.createArrayOf("bigint", parentIds));
            ps.executeUpdate();
        }
    }

    /**
     * cashflow_data — COPY через PgConnection.
     * Для больших JSONB-батчей COPY значительно быстрее INSERT:
     * данные передаются потоком без парсинга SQL и биндинга параметров.
     */
    private void saveCashflowDataViaCopy(Connection con,
                                         Long[] ids,
                                         String[] jsonBodies) throws SQLException {

        // Разворачиваем HikariCP-прокси до реального PgConnection
        PGConnection pgCon = con.unwrap(PGConnection.class);
        CopyManager copyManager = pgCon.getCopyAPI();

        String copySql = "COPY cashflow_data (id, content, created_at) FROM STDIN WITH (FORMAT csv, DELIMITER ',', QUOTE '\"')";

        try {
            // Пишем CSV-поток прямо в PostgreSQL
            // Используем ByteArrayOutputStream для формирования данных
            ByteArrayOutputStream baos = new ByteArrayOutputStream(ids.length * 512);
            Writer writer = new OutputStreamWriter(baos, StandardCharsets.UTF_8);

            String nowTimestamp = java.time.OffsetDateTime.now().toString();

            for (int i = 0; i < ids.length; i++) {
                // id — числовое, без кавычек
                writer.write(ids[i].toString());
                writer.write(',');

                // content — JSONB, оборачиваем в двойные кавычки,
                // экранируем внутренние двойные кавычки удвоением ("")
                writer.write('"');
                writer.write(escapeForCsv(jsonBodies[i]));
                writer.write('"');
                writer.write(',');

                // created_at
                writer.write('"');
                writer.write(nowTimestamp);
                writer.write('"');
                writer.write('\n');
            }

            writer.flush();

            byte[] bytes = baos.toByteArray();
            try (InputStream is = new ByteArrayInputStream(bytes)) {
                copyManager.copyIn(copySql, is);
            }

        } catch (IOException e) {
            throw new SQLException("Failed to COPY cashflow_data", e);
        }
    }

    /**
     * cashflow_index — статический SQL + UNNEST.
     */
    private void saveCashflowIndex(Connection con,
                                   Long[] ids,
                                   java.sql.Date[] paymentDates,
                                   BigDecimal[] paymentAmounts,
                                   String[] paymentCurrencies) throws SQLException {

        String sql = """
                INSERT INTO cashflow_index (id, payment_date, payment_amount, payment_currency, created_at)
                SELECT u.id, u.payment_date, u.payment_amount, u.payment_currency, now()
                FROM UNNEST(?::bigint[], ?::date[], ?::numeric[], ?::varchar[])
                    AS u(id, payment_date, payment_amount, payment_currency)
                """;

        try (PreparedStatement ps = con.prepareStatement(sql)) {
            ps.setArray(1, con.createArrayOf("bigint", ids));
            ps.setArray(2, con.createArrayOf("date", paymentDates));
            ps.setArray(3, con.createArrayOf("numeric", paymentAmounts));
            ps.setArray(4, con.createArrayOf("varchar", paymentCurrencies));
            ps.executeUpdate();
        }
    }

    /**
     * Экранирование строки для CSV-формата:
     * двойные кавычки удваиваются ("" вместо ").
     */
    private String escapeForCsv(String value) {
        if (value == null) {
            return "";
        }
        return value.replace("\"", "\"\"");
    }
}
```

## Необходимые импорты

```java
import com.fasterxml.jackson.core.JsonProcessingException;
import org.postgresql.PGConnection;
import org.postgresql.copy.CopyManager;
import org.springframework.jdbc.core.ConnectionCallback;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import lombok.extern.slf4j.Slf4j;

import java.io.*;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.SQLException;
import java.time.LocalDate;
import java.util.List;
```

## Обязательные настройки в `application.yml`

```yaml
spring:
  datasource:
    # reWriteBatchedInserts ускоряет любые batch-операции драйвера
    url: jdbc:postgresql://host:port/db?reWriteBatchedInserts=true
    hikari:
      maximum-pool-size: 20
      minimum-idle: 5
```

## Что здесь сделано и почему

| Таблица | Метод | Почему именно так |
|---|---|---|
| `cashflow_main` | `UNNEST` + статический SQL | Нет JSONB, простые типы — UNNEST идеален, план кэшируется |
| `cashflow_data` | `COPY ... FROM STDIN` | Большие JSONB-тела — COPY передаёт данные потоком, минуя парсер SQL и биндинг параметров. Это **самый быстрый** способ вставки в PostgreSQL |
| `cashflow_index` | `UNNEST` + статический SQL | Простые типы (date, numeric, varchar) — UNNEST идеален |

## Ключевые улучшения

1. **Нет динамической генерации SQL** — все три запроса статические, PostgreSQL кэширует планы
2. **COPY для JSONB** — данные передаются бинарным потоком, нет overhead на парсинг тысяч `?::jsonb` плейсхолдеров
3. **Нет `ObjectMapper` создания в каждом вызове** — убрал `new ObjectMapper()` который создавался, но не использовался
4. **Одно соединение** — все три операции выполняются в рамках одного `ConnectionCallback`, без лишних round-trip к пулу
5. **Минимум аллокаций** — массивы примитивных обёрток вместо `ArrayList<Object>` со склейкой строк
