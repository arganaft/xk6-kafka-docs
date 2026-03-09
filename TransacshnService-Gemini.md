Судя по вашему описанию и результатам тестов, проблема **не в дисковой подсистеме (I/O)** и **не в блокировках партиций**. Тот факт, что вставка только неизменяемых строк (Cashflow) показала даже *худший* результат (1720 объектов/сек против 2300+), является главным ключом к разгадке.

Ваша главная проблема — **CPU-bound процесс парсинга и планирования гигантских динамических SQL-запросов** как на стороне Java, так и на стороне PostgreSQL, а также неэффективная передача данных.

Вот детальный разбор узких мест и способы их устранения, которые дадут кратный прирост производительности.

---

### 1. Главная ошибка: Динамическая генерация `VALUES (...), (...), ...`
В каждом репозитории вы делаете цикл `for`, в котором склеиваете SQL-строку:
```java
sql.append("(?::bigint, ?::varchar, ?::bigint, now())");
```
**Почему это убивает производительность:**
1. **Отсутствие кэширования плана запроса:** Для PostgreSQL строка с 50 параметрами и строка с 51 параметром — это **разные** запросы. База данных тратит огромное количество процессорного времени на синтаксический анализ (parsing) и построение плана (planning) для *каждого* батча.
2. **Ограничения JDBC:** Драйверу приходится биндить тысячи параметров по одному.
3. **Garbage Collection (Java):** Склейка огромных строк через `StringBuilder` и создание тысяч объектов в памяти нагружает GC.

### Решение 1: Использование массивов PostgreSQL и `UNNEST` (Идеально для ваших CTE)
Вместо того чтобы генерировать строку с плейсхолдерами, вы должны использовать **один статический SQL-запрос** и передавать данные в виде массивов. PostgreSQL мгновенно разворачивает их через функцию `UNNEST`.

Пример переписывания `ContractsRepository` (или начала `FxSpotForwardRepository`):

```java
@Override
public int save(List<ObjectRequest> contracts) throws JsonProcessingException {
    // 1. Подготавливаем массивы колонок
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
        revisions[i] = obj.getHeader().getRevision() != null ? obj.getHeader().getRevision() : data.getRevision();
        versions[i] = obj.getHeader().getVersion() != null ? obj.getHeader().getVersion() : data.getVersion();
        tokens[i] = obj.getHeader().getLockId();
    }

    // 2. Статический SQL запрос! Он парсится базой ОДИН РАЗ.
    String sql = """
        WITH src_from_app AS (
            SELECT * FROM UNNEST(
                ?::bigint[], ?::varchar[], ?::bigint[], ?::int[], ?::int[], ?::varchar[]
            ) AS appTable(id, object_class, global_id, revision, version, token)
        ),
        records_lock_check AS ( ... ) -- Дальше ваш неизменный код
        MERGE INTO murex.contract_main AS mcm ...
        """;

    // 3. Выполняем запрос, передавая массивы
    return jdbcTemplate.execute((ConnectionCallback<Integer>) con -> {
        try (PreparedStatement ps = con.prepareStatement(sql)) {
            ps.setArray(1, con.createArrayOf("bigint", ids));
            ps.setArray(2, con.createArrayOf("varchar", objectClasses));
            ps.setArray(3, con.createArrayOf("bigint", globalIds));
            ps.setArray(4, con.createArrayOf("integer", revisions));
            ps.setArray(5, con.createArrayOf("integer", versions));
            ps.setArray(6, con.createArrayOf("varchar", tokens));
            
            return ps.executeUpdate();
        }
    });
}
```
**Эффект:** База данных строит план запроса 1 раз. Передача данных по сети сжимается. Парсинг SQL занимает 0 миллисекунд.

### Решение 2: Использование `jdbcTemplate.batchUpdate` для простых вставок
Для таблиц типа `cashflow_main`, `cashflow_data`, где нет сложной логики `MERGE/CTE`, используйте стандартный батчинг JDBC.

```java
// Обязательно добавьте в application.yml (или свойства подключения):
// spring.datasource.url: jdbc:postgresql://host:port/db?reWriteBatchedInserts=true

@Override
public int save(List<ObjectRequest> request) {
    String sqlMain = "INSERT INTO cashflow_main (id, object_class, parent_id, created_at) VALUES (?, ?, ?, now())";
    
    jdbcTemplate.batchUpdate(sqlMain, new BatchPreparedStatementSetter() {
        @Override
        public void setValues(PreparedStatement ps, int i) throws SQLException {
            var obj = request.get(i);
            var data = (CashflowObjectRequest) obj.getData();
            ps.setLong(1, obj.getHeader().getId());
            ps.setString(2, data.getObjectType());
            ps.setLong(3, obj.getHeader().getParentId());
        }

        @Override
        public int getBatchSize() {
            return request.size();
        }
    });
    // Повторить для cashflow_data и cashflow_index
    return request.size();
}
```
Параметр `reWriteBatchedInserts=true` в URL драйвера PostgreSQL заставит его "под капотом" собрать эффективный мульти-инсерт, но без накладных расходов на парсинг гигантских строк.

---

### 3. Блокировки и `FOR UPDATE` в CTE (FxSpotForwardRepository)
В вашем запросе `FxSpotForwardRepository` есть строка:
```sql
ORDER BY tm.actual_from DESC LIMIT 1 FOR UPDATE OF tm
```
Вы берете эксклюзивную блокировку на строки таблицы `trade_main`.
Если у вас работает **несколько подов (инстансов) приложения**, и они параллельно пытаются закоммитить сделки с одним и тем же `global_id` (или пересекающимися), они выстраиваются в очередь на уровне БД.
*   **Что делать:** Убедитесь, что ваш `KafkaMessagingService` (или то, что инициирует транзакции) использует партицирование по ключу (например, по `global_id` или `contract_id`). Все изменения по одному контракту/сделке должны обрабатываться строго одним потоком/подом.

---

### 4. Оптимизация работы с JSONB
Вы передаете `.getJsonBody()` как строку. PostgreSQL тратит процессорное время на парсинг этой строки в бинарный формат `JSONB` при каждой вставке.
В таблице `..._data` у вас только `id`, `content` и `created_at`.
Если размер JSON большой, это узкое место.
*   **Рекомендация:** Убедитесь, что вы не пишете в `JSONB` форматированный JSON (с пробелами и переносами строк).
*   Используйте `PGobject` для передачи JSON, чтобы драйвер работал с ним эффективнее:
```java
PGobject jsonObject = new PGobject();
jsonObject.setType("jsonb");
jsonObject.setValue(obj.getJsonBody());
ps.setObject(index, jsonObject);
```

---

### 5. Настройки пула соединений (HikariCP)
Так как коммит у вас происходит пачками, убедитесь, что настройки пула базы данных в Spring Boot оптимизированы:
```yaml
spring:
  datasource:
    hikari:
      maximum-pool-size: 20 # Не делайте слишком большим! (Кол-во ядер CPU * 2) + эффективные диски
      minimum-idle: 5
      prepStmtCacheSize: 250
      prepStmtCacheSqlLimit: 2048
      useServerPrepStmts: true
```
Кэширование `PreparedStatement` (последние 3 параметра) в связке с `UNNEST` (Решение 1) даст колоссальный буст.

### Резюме: План действий
1. **Срочно:** Перепишите генерацию SQL через `StringBuilder` на статические запросы.
2. Для сложных запросов с `CTE` (`FxSpotForward`, `Contracts`) используйте **массивы и `UNNEST`**.
3. Для простых `INSERT` (`Cashflow`, таблицы `_data`, `_index`) используйте **`jdbcTemplate.batchUpdate`** и обязательно добавьте `reWriteBatchedInserts=true` в строку подключения к БД.
4. Проверьте, не возникает ли гонки блокировок (Lock Contention) из-за `FOR UPDATE` при параллельной нагрузке.

Внедрив только `UNNEST` и `batchUpdate`, вы должны увидеть рост пропускной способности с 2000 до 10 000 - 20 000 объектов в секунду при тех же ресурсах.
