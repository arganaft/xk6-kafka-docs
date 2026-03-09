# Анализ узкого места и рекомендации по ускорению записи

## Диагностика проблемы

Судя по вашим метрикам, вы упираетесь в **~2300-2400 объектов/сек** независимо от оптимизаций схемы. Это классический симптом того, что узкое место — **не в самих SQL-запросах, а в накладных расходах на транзакции и round-trips**.

Давайте посчитаем: при 200 объектах за итерацию время ~210мс, при 50 объектах — ~65мс. Разница в 4x по объёму даёт только 3.2x по времени. Это значит, что есть **фиксированная overhead** на каждый коммит (~20-30мс), плюс линейная часть.

### Ключевые проблемы в коде:

**1. Множественные round-trips к БД в одной транзакции**

В `FxSpotForwardRepository.save()` вы делаете **2 отдельных вызова** к БД (основной CTE + вставка в index/data). В `ContractsRepository` — тоже 2. Каждый `jdbcTemplate.update()` — это отдельный network round-trip.

**2. Цикл по типам внутри `@Transactional`**

```java
for (String type : types) {
    // для каждого типа — отдельные батчи, каждый батч — отдельные SQL-вызовы
    for (long offset = 0; offset < size; offset += batchSize) {
        saveStrategyToDb.save(batchObjects); // 2-3 round-trips каждый
    }
}
```

При 4 типах и нескольких батчах вы можете делать **8-12 round-trips** к PostgreSQL в одной транзакции.

**3. `deleteCache` перед каждым `save` — синхронный Redis вызов внутри DB-транзакции**

Это увеличивает время удержания PostgreSQL-транзакции, что усиливает contention на блокировках.

**4. `FOR UPDATE` в CTE FxSpotForward**

```sql
FOR UPDATE OF tm
```

Это создаёт row-level locks и сериализует параллельные транзакции, работающие с одними и теми же `global_id`.

## Рекомендации по ускорению

### 1. Объединить все SQL в один round-trip

Вместо 2-3 отдельных `jdbcTemplate.update()` — один batch statement:

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
        // Собираем ВСЁ в один SQL-запрос
        StringBuilder sql = new StringBuilder();
        List<Object> allParams = new ArrayList<>();

        // ===== Часть 1: основной CTE с MERGE/INSERT =====
        sql.append("""
                WITH src_from_app AS (
                SELECT *
                FROM (VALUES
        """);

        for (int i = 0; i < request.size(); i++) {
            if (i > 0) sql.append(",");
            sql.append("(?::bigint, ?::varchar, ?::bigint, ?::date, ?::bool, ?::int, ?::int, ?::varchar)");
            var obj = request.get(i);
            var data = (FxSpotForwardObjectRequest) obj.getData();
            allParams.add(obj.getHeader().getId());
            allParams.add(data.getObjectType());
            allParams.add(obj.getHeader().getGlobalId());
            allParams.add(LocalDate.parse(obj.getHeader().getActualFrom()));
            allParams.add(obj.getHeader().getDraftStatus().equals("DRAFT"));
            allParams.add(obj.getHeader().getRevision());
            allParams.add(obj.getHeader().getVersion());
            allParams.add(obj.getHeader().getLockId());
        }

        sql.append("""
                ) AS app_table(id, object_class, global_id, actual_from, draft_status, revision, version, token)
            ),
            const AS (
              SELECT NOW()::TIMESTAMP AS ts_now, DATE '3000-01-01' AS biz_inf, TIMESTAMP '3000-01-01 00:00:00' AS tech_inf
            ),
            lock_check AS (
              SELECT NOT EXISTS (
                SELECT 1 FROM src_from_app s
                LEFT JOIN murex.object_lock l ON l.token = s.token AND l.expire >= NOW()
                WHERE l.token IS NULL
              ) AS all_records_have_lock
            ),
            active_seg AS (
              SELECT s.*, seg.actual_from AS seg_from, seg.actual_to AS seg_to
              FROM src_from_app s
              LEFT JOIN LATERAL (
                SELECT tm.actual_from, tm.actual_to FROM trade_main tm CROSS JOIN const c
                WHERE tm.object_class = s.object_class AND tm.global_id = s.global_id
                  AND tm.closed_at = c.tech_inf AND s.actual_from >= tm.actual_from AND s.actual_from < tm.actual_to
                ORDER BY tm.actual_from DESC LIMIT 1 FOR UPDATE OF tm
              ) seg ON TRUE
            ),
            src_norm AS (
              SELECT a.id, a.object_class, a.global_id, a.actual_from,
                c.biz_inf AS actual_to, a.draft_status, a.revision,
                CASE WHEN a.draft_status = false THEN a.version ELSE NULL END AS version,
                a.seg_from, a.seg_to, a.token
              FROM active_seg a CROSS JOIN const c
            ),
            cut_business_period AS (
               UPDATE trade_main tm SET actual_to = s.actual_from
               FROM src_norm s CROSS JOIN const c JOIN lock_check lc ON lc.all_records_have_lock
               WHERE s.seg_from IS NOT NULL AND s.actual_from > s.seg_from
                 AND tm.object_class = s.object_class AND tm.global_id = s.global_id
                 AND tm.closed_at = c.tech_inf AND tm.actual_from = s.seg_from AND tm.actual_to = s.seg_to
                 AND s.draft_status = false AND tm.draft_status = false
            ),
            close_technical AS (
               UPDATE trade_main tm SET closed_at = c.ts_now
               FROM src_norm s CROSS JOIN const c JOIN lock_check lc ON lc.all_records_have_lock
               WHERE tm.object_class = s.object_class AND tm.global_id = s.global_id AND tm.closed_at = c.tech_inf
                 AND ((s.draft_status = true AND tm.draft_status = true)
                   OR (s.draft_status = false AND (tm.draft_status = true
                     OR (tm.draft_status = false AND s.seg_from IS NOT NULL
                       AND tm.actual_from = s.seg_from
                       AND tm.actual_to = CASE WHEN s.actual_from > s.seg_from THEN s.actual_from ELSE s.seg_to END))))
            ),
            ins AS (
              INSERT INTO trade_main (id, object_class, global_id, actual_from, actual_to, draft_status, revision, version, saved_at, closed_at)
              SELECT s.id, s.object_class, s.global_id, s.actual_from, s.actual_to, s.draft_status, s.revision, s.version, c.ts_now, c.tech_inf
              FROM src_norm s CROSS JOIN const c JOIN lock_check lc ON lc.all_records_have_lock
              RETURNING id
            ),
            ins_count AS (SELECT COUNT(*) AS cnt FROM ins)
            """);

        // ===== Часть 2: вставка в index (через тот же CTE) =====
        sql.append("""
            , ins_fx_index AS (
              INSERT INTO fx_spot_forward_index (id, national_amount, national_currency, created_at)
              SELECT s.id, s.national_amount, s.national_currency, NOW()
              FROM (VALUES
        """);

        for (int i = 0; i < request.size(); i++) {
            if (i > 0) sql.append(",");
            sql.append("(?::bigint, ?::numeric, ?::varchar)");
            var obj = request.get(i);
            var data = (FxSpotForwardObjectRequest) obj.getData();
            allParams.add(obj.getHeader().getId());
            allParams.add(data.getNotionalAmount());
            allParams.add(data.getNotionalCurrencyId().toString());
        }

        sql.append("""
              ) AS s(id, national_amount, national_currency)
              -- Вставляем только если основная вставка прошла
              WHERE (SELECT cnt FROM ins_count) > 0
            )
        """);

        // ===== Часть 3: вставка в data =====
        sql.append("""
            , ins_fx_data AS (
              INSERT INTO fx_spot_forward_data (id, content, created_at)
              SELECT s.id, s.content::jsonb, NOW()
              FROM (VALUES
        """);

        for (int i = 0; i < request.size(); i++) {
            if (i > 0) sql.append(",");
            sql.append("(?::bigint, ?::text)");
            var obj = request.get(i);
            allParams.add(obj.getHeader().getId());
            allParams.add(obj.getJsonBody());
        }

        sql.append("""
              ) AS s(id, content)
              WHERE (SELECT cnt FROM ins_count) > 0
            )
        """);

        // ===== Часть 4: вставка в trade_index =====
        sql.append("""
            , ins_trade_index AS (
              INSERT INTO trade_index (id, legal_entity_id, portfolio_id, contract_id, created_at)
              SELECT s.id, s.legal_entity_id, s.portfolio_id, s.contract_id, NOW()
              FROM (VALUES
        """);

        for (int i = 0; i < request.size(); i++) {
            if (i > 0) sql.append(",");
            sql.append("(?::bigint, ?::bigint, ?::bigint, ?::bigint)");
            var obj = request.get(i);
            var data = (FxSpotForwardObjectRequest) obj.getData();
            allParams.add(obj.getHeader().getId());
            allParams.add(data.getLegalEntityId());
            allParams.add(data.getPortfolioId());
            allParams.add(data.getContractId());
        }

        sql.append("""
              ) AS s(id, legal_entity_id, portfolio_id, contract_id)
              WHERE (SELECT cnt FROM ins_count) > 0
            )
            SELECT cnt FROM ins_count;
        """);

        // Один round-trip вместо двух
        return jdbcTemplate.execute((ConnectionCallback<Integer>) con -> {
            try (PreparedStatement ps = con.prepareStatement(sql.toString())) {
                for (int i = 0; i < allParams.size(); i++) {
                    ps.setObject(i + 1, allParams.get(i));
                }
                try (var rs = ps.executeQuery()) {
                    return rs.next() ? rs.getInt(1) : 0;
                }
            }
        });
    }
}
```

### 2. Вынести Redis deleteCache за пределы DB-транзакции

```java
@Transactional
public Map<String, Long> doCommit(UUID transactionId) {
    // ... получение types из Redis ...
    
    // Собираем все объекты ДО начала тяжёлой работы с БД
    Map<String, List<List<ObjectRequest>>> allBatches = new LinkedHashMap<>();
    
    for (String type : types) {
        String key = properties.stagingWithTypesKey(transactionId, type);
        Long size = stringRedisTemplate.opsForList().size(key);
        // ... валидация ...
        
        List<List<ObjectRequest>> typeBatches = new ArrayList<>();
        int batchSize = properties.getBatchSize();
        for (long offset = 0; offset < size; offset += batchSize) {
            long end = Math.min(offset + batchSize - 1, size - 1);
            List<String> entries = stringRedisTemplate.opsForList().range(key, offset, end);
            typeBatches.add(parseBatch(entries));
        }
        allBatches.put(type, typeBatches);
    }
    
    // Теперь только работа с БД — минимальное время транзакции
    Map<String, Long> sizeMap = new HashMap<>();
    for (var entry : allBatches.entrySet()) {
        String type = entry.getKey();
        var saveStrategy = saveRepositoryStrategyFactory.getSaveRepositoryStrategy(type);
        long totalInserted = 0;
        
        for (List<ObjectRequest> batch : entry.getValue()) {
            int inserted = saveStrategy.save(batch);
            totalInserted += inserted;
        }
        sizeMap.put(type, totalInserted);
    }
    
    return sizeMap;
}

// deleteCache вызывать ПОСЛЕ коммита, не внутри @Transactional
```

### 3. Использовать COPY вместо INSERT для больших батчей

Для неизменяемых таблиц (cashflow, data-таблицы) `COPY` значительно быстрее:

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
        // Используем COPY для массовой вставки
        jdbcTemplate.execute((ConnectionCallback<Void>) con -> {
            // Unwrap to PGConnection
            var pgCon = con.unwrap(org.postgresql.PGConnection.class);
            
            // COPY для cashflow_main
            var copyMain = new org.postgresql.copy.CopyManager(pgCon);
            StringBuilder mainData = new StringBuilder();
            for (var obj : request) {
                var data = (CashflowObjectRequest) obj.getData();
                mainData.append(obj.getHeader().getId()).append('\t')
                        .append(data.getObjectType()).append('\t')
                        .append(obj.getHeader().getParentId()).append('\t')
                        .append(java.time.LocalDateTime.now()).append('\n');
            }
            copyMain.copyIn(
                "COPY cashflow_main (id, object_class, parent_id, created_at) FROM STDIN",
                new java.io.StringReader(mainData.toString())
            );
            
            // COPY для cashflow_data
            StringBuilder dataContent = new StringBuilder();
            for (var obj : request) {
                // Экранируем табы и переводы строк в JSON
                String escaped = obj.getJsonBody()
                    .replace("\\", "\\\\")
                    .replace("\t", "\\t")
                    .replace("\n", "\\n");
                dataContent.append(obj.getHeader().getId()).append('\t')
                           .append(escaped).append('\t')
                           .append(java.time.LocalDateTime.now()).append('\n');
            }
            copyMain.copyIn(
                "COPY cashflow_data (id, content, created_at) FROM STDIN",
                new java.io.StringReader(dataContent.toString())
            );
            
            // COPY для cashflow_index
            StringBuilder indexData = new StringBuilder();
            for (var obj : request) {
                var data = (CashflowObjectRequest) obj.getData();
                indexData.append(obj.getHeader().getId()).append('\t')
                         .append(data.getPaymentDate()).append('\t')
                         .append(data.getPaymentAmount()).append('\t')
                         .append(data.getPaymentCurrencyId()).append('\t')
                         .append(java.time.LocalDateTime.now()).append('\n');
            }
            copyMain.copyIn(
                "COPY cashflow_index (id, payment_date, payment_amount, payment_currency, created_at) FROM STDIN",
                new java.io.StringReader(indexData.toString())
            );
            
            return null;
        });
        
        return request.size();
    }
}
```

### 4. Параллельная обработка типов (если нет зависимостей между типами)

```java
@Transactional
public Map<String, Long> doCommit(UUID transactionId) {
    // Предварительно читаем всё из Redis
    Map<String, List<List<ObjectRequest>>> allBatches = readAllFromRedis(transactionId);
    
    // Если типы независимы — можно использовать multi-statement
    // Собираем ВСЕ SQL в один огромный batch и отправляем за один round-trip
    return jdbcTemplate.execute((ConnectionCallback<Map<String, Long>>) con -> {
        Map<String, Long> result = new HashMap<>();
        
        try (var stmt = con.createStatement()) {
            for (var entry : allBatches.entrySet()) {
                String type = entry.getKey();
                for (List<ObjectRequest> batch : entry.getValue()) {
                    String sql = buildSqlForType(type, batch);
                    stmt.addBatch(sql);
                }
            }
            int[] results = stmt.executeBatch();
            // ... обработка результатов
        }
        
        return result;
    });
}
```

### 5. Настройки PostgreSQL для ускорения записи

```sql
-- Если допустима потеря последних транзакций при крэше (обычно ОК для staging)
ALTER SYSTEM SET synchronous_commit = 'off';

-- Увеличить размер WAL-буферов
ALTER SYSTEM SET wal_buffers = '64MB';

-- Увеличить checkpoint distance
ALTER SYSTEM SET max_wal_size = '4GB';
ALTER SYSTEM SET checkpoint_completion_target = 0.9;

-- Для batch-операций
ALTER SYSTEM SET effective_io_concurrency = 200;
```

### 6. Настройки connection pool (HikariCP)

```yaml
spring:
  datasource:
    hikari:
      maximum-pool-size: 20
      minimum-idle: 10
      connection-timeout: 5000
      # Критично! Prepared statement caching
      data-source-properties:
        preparedStatementCacheQueries: 256
        preparedStatementCacheSizeMiB: 5
        # Отправка нескольких statements за один round-trip
        reWriteBatchedInserts: true
```

### 7. Убрать `FOR UPDATE` и заменить на advisory locks

`FOR UPDATE` в CTE создаёт серьёзный contention. Advisory locks быстрее:

```sql
-- Вместо FOR UPDATE в LATERAL
-- Берём advisory lock на global_id в начале
SELECT pg_advisory_xact_lock(s.global_id) FROM src_from_app s;
-- Далее работаем без FOR UPDATE
```

## Ожидаемый эффект

| Оптимизация | Ожидаемый прирост |
|---|---|
| Один round-trip вместо 2-3 | **+30-50%** |
| Redis вне DB-транзакции | **+10-20%** |
| `synchronous_commit = off` | **+50-100%** |
| COPY для неизменяемых | **+20-40%** для cashflow |
| Advisory locks вместо FOR UPDATE | **+15-30%** при конкуренции |
| `reWriteBatchedInserts=true` | **+10-20%** |

**Суммарно** при применении всех оптимизаций можно ожидать **3-5x ускорение**, т.е. **7000-12000 объектов/сек**.

### Приоритет внедрения:

1. **`synchronous_commit = off`** — самый быстрый и значительный эффект, одна строка конфига
2. **Объединение SQL в один round-trip** — средняя сложность, большой эффект
3. **Вынос Redis из DB-транзакции** — простая рефакторинг
4. **COPY для простых INSERT** — средняя сложность
5. **Advisory locks** — требует тестирования на корректность
