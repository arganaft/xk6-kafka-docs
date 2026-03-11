

# Вариант 1: Без временной таблицы (UNNEST + плоский JOIN)

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
        if (request.isEmpty()) {
            return 0;
        }

        // ===== Шаг 0: Сортировка для предотвращения дедлоков =====
        request.sort(Comparator.comparing(r -> r.getHeader().getGlobalId()));

        int size = request.size();

        // ===== Шаг 1: Подготовка массивов =====
        Long[] ids = new Long[size];
        String[] objectClasses = new String[size];
        Long[] globalIds = new Long[size];
        java.sql.Date[] actualFroms = new java.sql.Date[size];
        Boolean[] draftStatuses = new Boolean[size];
        Integer[] revisions = new Integer[size];
        Integer[] versions = new Integer[size];
        String[] tokens = new String[size];

        for (int i = 0; i < size; i++) {
            var obj = request.get(i);
            var header = obj.getHeader();
            var data = (FxSpotForwardObjectRequest) obj.getData();

            ids[i] = header.getId();
            objectClasses[i] = data.getObjectType();
            globalIds[i] = header.getGlobalId();
            actualFroms[i] = java.sql.Date.valueOf(LocalDate.parse(header.getActualFrom()));
            draftStatuses[i] = "DRAFT".equals(header.getDraftStatus());
            revisions[i] = header.getRevision();
            versions[i] = header.getVersion();
            tokens[i] = header.getLockId();
        }

        // ===== Шаг 2: Fail-Fast проверка блокировок =====
        checkLocksOrThrow(tokens);

        // ===== Шаг 3: Основной CTE (плоский, без LATERAL) =====
        Integer insertedRows = executeMainUpsert(
                ids, objectClasses, globalIds, actualFroms,
                draftStatuses, revisions, versions
        );

        if (insertedRows == 0) {
            log.warn("No rows inserted into trade_main.");
            return 0;
        }

        // ===== Шаг 4: Вставка данных в дочерние таблицы =====
        copyFxSpotForwardData(request);
        batchInsertFxSpotForwardIndex(request);
        batchInsertTradeIndex(request);

        return insertedRows;
    }

    /**
     * Fail-Fast: быстрая проверка что все токены валидны.
     * Выполняется ДО тяжёлого запроса, чтобы не тратить ресурсы впустую.
     */
    private void checkLocksOrThrow(String[] tokens) {
        Boolean locksMissing = jdbcTemplate.execute((ConnectionCallback<Boolean>) con -> {
            String sql = """
                    SELECT EXISTS (
                        SELECT 1
                        FROM UNNEST(?::varchar[]) AS t(token)
                        LEFT JOIN murex.object_lock l
                            ON l.token = t.token
                           AND l.expire >= NOW()
                        WHERE l.token IS NULL
                    )
                    """;
            try (PreparedStatement ps = con.prepareStatement(sql)) {
                ps.setArray(1, con.createArrayOf("varchar", tokens));
                try (var rs = ps.executeQuery()) {
                    return rs.next() && rs.getBoolean(1);
                }
            }
        });

        if (Boolean.TRUE.equals(locksMissing)) {
            throw new IllegalStateException(
                    "Missing valid locks for batch. Aborting before heavy query.");
        }
    }

    /**
     * Основной запрос: плоский CTE без LATERAL.
     * 
     * Логика:
     * 1) locked_targets — массово блокирует ВСЕ активные строки trade_main
     *    по (object_class, global_id), отсортированные для предсказуемого порядка.
     * 2) matched — находит для каждой входной записи "текущий активный сегмент"
     *    через обычный JOIN + DISTINCT ON (без LATERAL).
     * 3) updated — один UPDATE с CASE, объединяющий логику
     *    cut_business_period и close_technical.
     * 4) ins — вставка новых записей.
     */
    private Integer executeMainUpsert(
            Long[] ids, String[] objectClasses, Long[] globalIds,
            java.sql.Date[] actualFroms, Boolean[] draftStatuses,
            Integer[] revisions, Integer[] versions
    ) {
        String mainSql = """
                WITH src AS (
                    SELECT *
                    FROM UNNEST(
                        ?::bigint[], ?::varchar[], ?::bigint[], ?::date[],
                        ?::bool[], ?::int[], ?::int[]
                    ) AS app(id, object_class, global_id, actual_from,
                             draft_status, revision, version)
                ),
                const AS (
                    SELECT
                        NOW()::TIMESTAMP                AS ts_now,
                        DATE '3000-01-01'               AS biz_inf,
                        TIMESTAMP '3000-01-01 00:00:00' AS tech_inf
                ),
                -- Массовое взятие блокировок в предсказуемом порядке.
                -- Входные данные уже отсортированы по global_id в Java.
                locked_targets AS (
                    SELECT tm.id AS tm_id,
                           tm.object_class,
                           tm.global_id,
                           tm.actual_from  AS tm_actual_from,
                           tm.actual_to    AS tm_actual_to,
                           tm.draft_status AS tm_draft_status
                    FROM trade_main tm
                    JOIN (SELECT DISTINCT object_class, global_id FROM src) s
                        ON tm.object_class = s.object_class
                       AND tm.global_id = s.global_id
                    CROSS JOIN const c
                    WHERE tm.closed_at = c.tech_inf
                    ORDER BY tm.global_id, tm.object_class
                    FOR UPDATE OF tm
                ),
                -- Для каждой входной записи находим "активный сегмент":
                -- строку из locked_targets, в чей период [actual_from, actual_to)
                -- попадает s.actual_from. Берём ближайшую снизу.
                matched AS (
                    SELECT DISTINCT ON (s.id)
                        s.id,
                        s.object_class,
                        s.global_id,
                        s.actual_from,
                        s.draft_status,
                        s.revision,
                        CASE WHEN s.draft_status = false
                             THEN s.version ELSE NULL END AS version,
                        lt.tm_id           AS seg_tm_id,
                        lt.tm_actual_from  AS seg_from,
                        lt.tm_actual_to    AS seg_to,
                        lt.tm_draft_status AS seg_draft_status
                    FROM src s
                    LEFT JOIN locked_targets lt
                        ON lt.object_class = s.object_class
                       AND lt.global_id = s.global_id
                       AND s.actual_from >= lt.tm_actual_from
                       AND s.actual_from <  lt.tm_actual_to
                    ORDER BY s.id, lt.tm_actual_from DESC
                ),
                -- Один UPDATE вместо двух отдельных CTE.
                -- Объединяет логику cut_business_period + close_technical.
                --
                -- Для каждой заблокированной строки trade_main определяем:
                --   closed_at: закрыть технически или оставить
                --   actual_to: обрезать бизнес-период или оставить
                updated AS (
                    UPDATE trade_main tm
                    SET
                        actual_to = CASE
                            -- cut_business_period:
                            -- Новая CONFIRMED, старая CONFIRMED, новая дата > начала сегмента
                            WHEN m.draft_status = false
                                 AND tm.draft_status = false
                                 AND m.seg_from IS NOT NULL
                                 AND m.actual_from > m.seg_from
                                 AND tm.actual_from = m.seg_from
                                 AND tm.actual_to = m.seg_to
                            THEN m.actual_from
                            ELSE tm.actual_to
                        END,
                        closed_at = CASE
                            -- close_technical: DRAFT → закрываем только DRAFT
                            WHEN m.draft_status = true
                                 AND tm.draft_status = true
                            THEN c.ts_now

                            -- close_technical: CONFIRMED → закрываем все DRAFT
                            WHEN m.draft_status = false
                                 AND tm.draft_status = true
                            THEN c.ts_now

                            -- close_technical: CONFIRMED → закрываем CONFIRMED
                            -- если это тот же сегмент и actual_to уже обрезан
                            WHEN m.draft_status = false
                                 AND tm.draft_status = false
                                 AND m.seg_from IS NOT NULL
                                 AND tm.actual_from = m.seg_from
                                 AND tm.actual_to = CASE
                                     WHEN m.actual_from > m.seg_from THEN m.actual_from
                                     ELSE m.seg_to
                                 END
                            THEN c.ts_now

                            ELSE tm.closed_at
                        END
                    FROM matched m
                    CROSS JOIN const c
                    WHERE tm.object_class = m.object_class
                      AND tm.global_id = m.global_id
                      AND tm.closed_at = c.tech_inf
                      AND (
                          -- Строка подлежит обновлению если выполняется
                          -- хотя бы одно из условий:
                          (m.draft_status = true AND tm.draft_status = true)
                          OR
                          (m.draft_status = false AND tm.draft_status = true)
                          OR
                          (m.draft_status = false
                           AND tm.draft_status = false
                           AND m.seg_from IS NOT NULL
                           AND tm.actual_from = m.seg_from)
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
                        m.id, m.object_class, m.global_id,
                        m.actual_from, c.biz_inf,
                        m.draft_status,
                        m.revision, m.version,
                        c.ts_now, c.tech_inf
                    FROM matched m
                    CROSS JOIN const c
                    RETURNING id
                )
                SELECT COUNT(*) FROM ins
                """;

        return jdbcTemplate.execute((ConnectionCallback<Integer>) con -> {
            try (PreparedStatement ps = con.prepareStatement(mainSql)) {
                ps.setArray(1, con.createArrayOf("bigint", ids));
                ps.setArray(2, con.createArrayOf("varchar", objectClasses));
                ps.setArray(3, con.createArrayOf("bigint", globalIds));
                ps.setArray(4, con.createArrayOf("date", actualFroms));
                ps.setArray(5, con.createArrayOf("boolean", draftStatuses));
                ps.setArray(6, con.createArrayOf("integer", revisions));
                ps.setArray(7, con.createArrayOf("integer", versions));

                try (var rs = ps.executeQuery()) {
                    return rs.next() ? rs.getInt(1) : 0;
                }
            }
        });
    }

    /**
     * COPY для fx_spot_forward_data — потоковая запись без StringBuilder.
     */
    private void copyFxSpotForwardData(List<ObjectRequest> request) {
        jdbcTemplate.execute((ConnectionCallback<Void>) con -> {
            PGConnection pgConn = con.unwrap(PGConnection.class);

            String copySql = "COPY fx_spot_forward_data (id, content, created_at) "
                    + "FROM STDIN WITH (FORMAT csv, DELIMITER E'\\t', QUOTE E'\\x01')";

            Timestamp now = Timestamp.valueOf(LocalDateTime.now());

            try (var out = new PGCopyOutputStream(pgConn, copySql)) {
                for (ObjectRequest obj : request) {
                    StringBuilder line = new StringBuilder(256);
                    line.append(obj.getHeader().getId());
                    line.append('\t');
                    line.append('\u0001');
                    line.append(obj.getJsonBody());
                    line.append('\u0001');
                    line.append('\t');
                    line.append(now.toString());
                    line.append('\n');

                    out.write(line.toString().getBytes(StandardCharsets.UTF_8));
                }
            }

            return null;
        });
    }

    /**
     * batchUpdate для fx_spot_forward_index.
     * С reWriteBatchedInserts=true драйвер склеит в multi-row INSERT.
     */
    private void batchInsertFxSpotForwardIndex(List<ObjectRequest> request) {
        String sql = "INSERT INTO fx_spot_forward_index "
                + "(id, national_amount, national_currency, created_at) "
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
        String sql = "INSERT INTO trade_index "
                + "(id, legal_entity_id, portfolio_id, contract_id, created_at) "
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

### Индексы для Варианта 1

```sql
-- Главный индекс для locked_targets и matched:
-- JOIN по (object_class, global_id) + фильтр по closed_at
CREATE INDEX IF NOT EXISTS idx_trade_main_oc_gid_closed
    ON trade_main (object_class, global_id, closed_at);

-- Покрывающий индекс (если хотите избежать обращения к heap):
CREATE INDEX IF NOT EXISTS idx_trade_main_oc_gid_closed_covering
    ON trade_main (object_class, global_id, closed_at)
    INCLUDE (actual_from, actual_to, draft_status);

-- Для проверки блокировок (lock_check)
CREATE INDEX IF NOT EXISTS idx_object_lock_token_expire
    ON murex.object_lock (token, expire);
```

---

# Вариант 2: С временной таблицей (TEMP TABLE + ANALYZE)

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
        if (request.isEmpty()) {
            return 0;
        }

        // ===== Шаг 0: Сортировка для предотвращения дедлоков =====
        request.sort(Comparator.comparing(r -> r.getHeader().getGlobalId()));

        int size = request.size();

        Long[] ids = new Long[size];
        String[] objectClasses = new String[size];
        Long[] globalIds = new Long[size];
        java.sql.Date[] actualFroms = new java.sql.Date[size];
        Boolean[] draftStatuses = new Boolean[size];
        Integer[] revisions = new Integer[size];
        Integer[] versions = new Integer[size];
        String[] tokens = new String[size];

        for (int i = 0; i < size; i++) {
            var obj = request.get(i);
            var header = obj.getHeader();
            var data = (FxSpotForwardObjectRequest) obj.getData();

            ids[i] = header.getId();
            objectClasses[i] = data.getObjectType();
            globalIds[i] = header.getGlobalId();
            actualFroms[i] = java.sql.Date.valueOf(LocalDate.parse(header.getActualFrom()));
            draftStatuses[i] = "DRAFT".equals(header.getDraftStatus());
            revisions[i] = header.getRevision();
            versions[i] = header.getVersion();
            tokens[i] = header.getLockId();
        }

        // ===== Шаг 1: Fail-Fast проверка блокировок =====
        checkLocksOrThrow(tokens);

        // ===== Шаг 2: Создание temp table + ANALYZE + основной запрос =====
        Integer insertedRows = executeWithTempTable(
                ids, objectClasses, globalIds, actualFroms,
                draftStatuses, revisions, versions
        );

        if (insertedRows == 0) {
            log.warn("No rows inserted into trade_main.");
            return 0;
        }

        // ===== Шаг 3: Вставка данных в дочерние таблицы =====
        copyFxSpotForwardData(request);
        batchInsertFxSpotForwardIndex(request);
        batchInsertTradeIndex(request);

        return insertedRows;
    }

    private void checkLocksOrThrow(String[] tokens) {
        Boolean locksMissing = jdbcTemplate.execute((ConnectionCallback<Boolean>) con -> {
            String sql = """
                    SELECT EXISTS (
                        SELECT 1
                        FROM UNNEST(?::varchar[]) AS t(token)
                        LEFT JOIN murex.object_lock l
                            ON l.token = t.token
                           AND l.expire >= NOW()
                        WHERE l.token IS NULL
                    )
                    """;
            try (PreparedStatement ps = con.prepareStatement(sql)) {
                ps.setArray(1, con.createArrayOf("varchar", tokens));
                try (var rs = ps.executeQuery()) {
                    return rs.next() && rs.getBoolean(1);
                }
            }
        });

        if (Boolean.TRUE.equals(locksMissing)) {
            throw new IllegalStateException(
                    "Missing valid locks for batch. Aborting before heavy query.");
        }
    }

    /**
     * Весь процесс выполняется на одном соединении (одна транзакция):
     * 1) CREATE TEMP TABLE
     * 2) INSERT INTO temp через UNNEST (мгновенно)
     * 3) ANALYZE temp (даёт планировщику реальную статистику)
     * 4) SELECT ... FOR UPDATE (массовая блокировка)
     * 5) UPDATE trade_main (один проход, CASE-логика)
     * 6) INSERT INTO trade_main
     */
    private Integer executeWithTempTable(
            Long[] ids, String[] objectClasses, Long[] globalIds,
            java.sql.Date[] actualFroms, Boolean[] draftStatuses,
            Integer[] revisions, Integer[] versions
    ) {
        return jdbcTemplate.execute((ConnectionCallback<Integer>) con -> {

            // --- 1) Создаём временную таблицу ---
            try (var stmt = con.createStatement()) {
                stmt.execute("""
                        CREATE TEMP TABLE IF NOT EXISTS _batch_src (
                            id          BIGINT      NOT NULL,
                            object_class VARCHAR     NOT NULL,
                            global_id   BIGINT      NOT NULL,
                            actual_from DATE        NOT NULL,
                            draft_status BOOLEAN    NOT NULL,
                            revision    INTEGER,
                            version     INTEGER
                        ) ON COMMIT DELETE ROWS
                        """);
            }

            // --- 2) Заполняем через UNNEST ---
            String insertTempSql = """
                    INSERT INTO _batch_src (id, object_class, global_id,
                                            actual_from, draft_status,
                                            revision, version)
                    SELECT *
                    FROM UNNEST(
                        ?::bigint[], ?::varchar[], ?::bigint[], ?::date[],
                        ?::bool[], ?::int[], ?::int[]
                    )
                    """;

            try (PreparedStatement ps = con.prepareStatement(insertTempSql)) {
                ps.setArray(1, con.createArrayOf("bigint", ids));
                ps.setArray(2, con.createArrayOf("varchar", objectClasses));
                ps.setArray(3, con.createArrayOf("bigint", globalIds));
                ps.setArray(4, con.createArrayOf("date", actualFroms));
                ps.setArray(5, con.createArrayOf("boolean", draftStatuses));
                ps.setArray(6, con.createArrayOf("integer", revisions));
                ps.setArray(7, con.createArrayOf("integer", versions));
                ps.executeUpdate();
            }

            // --- 3) ANALYZE — даёт планировщику реальную статистику ---
            try (var stmt = con.createStatement()) {
                stmt.execute("ANALYZE _batch_src");
            }

            // --- 4) Основной запрос ---
            // Планировщик теперь знает сколько строк в _batch_src
            // и может выбрать Hash Join вместо Nested Loops
            String mainSql = """
                    WITH const AS (
                        SELECT
                            NOW()::TIMESTAMP                AS ts_now,
                            DATE '3000-01-01'               AS biz_inf,
                            TIMESTAMP '3000-01-01 00:00:00' AS tech_inf
                    ),
                    -- Массовая блокировка всех затронутых строк trade_main.
                    -- Порядок предсказуем благодаря сортировке в Java.
                    locked_targets AS (
                        SELECT
                            tm.id       AS tm_id,
                            tm.object_class,
                            tm.global_id,
                            tm.actual_from  AS tm_actual_from,
                            tm.actual_to    AS tm_actual_to,
                            tm.draft_status AS tm_draft_status
                        FROM trade_main tm
                        JOIN (SELECT DISTINCT object_class, global_id
                              FROM _batch_src) s
                            ON tm.object_class = s.object_class
                           AND tm.global_id = s.global_id
                        CROSS JOIN const c
                        WHERE tm.closed_at = c.tech_inf
                        ORDER BY tm.global_id, tm.object_class
                        FOR UPDATE OF tm
                    ),
                    -- Для каждой входной записи находим активный сегмент
                    -- через обычный JOIN (Hash Join благодаря ANALYZE)
                    matched AS (
                        SELECT DISTINCT ON (s.id)
                            s.id,
                            s.object_class,
                            s.global_id,
                            s.actual_from,
                            s.draft_status,
                            s.revision,
                            CASE WHEN s.draft_status = false
                                 THEN s.version ELSE NULL END AS version,
                            lt.tm_id,
                            lt.tm_actual_from  AS seg_from,
                            lt.tm_actual_to    AS seg_to,
                            lt.tm_draft_status AS seg_draft_status
                        FROM _batch_src s
                        LEFT JOIN locked_targets lt
                            ON lt.object_class = s.object_class
                           AND lt.global_id = s.global_id
                           AND s.actual_from >= lt.tm_actual_from
                           AND s.actual_from <  lt.tm_actual_to
                        ORDER BY s.id, lt.tm_actual_from DESC
                    ),
                    -- Один UPDATE: объединяет cut_business_period + close_technical
                    updated AS (
                        UPDATE trade_main tm
                        SET
                            actual_to = CASE
                                WHEN m.draft_status = false
                                     AND tm.draft_status = false
                                     AND m.seg_from IS NOT NULL
                                     AND m.actual_from > m.seg_from
                                     AND tm.actual_from = m.seg_from
                                     AND tm.actual_to = m.seg_to
                                THEN m.actual_from
                                ELSE tm.actual_to
                            END,
                            closed_at = CASE
                                -- DRAFT → закрываем DRAFT
                                WHEN m.draft_status = true
                                     AND tm.draft_status = true
                                THEN c.ts_now

                                -- CONFIRMED → закрываем все DRAFT
                                WHEN m.draft_status = false
                                     AND tm.draft_status = true
                                THEN c.ts_now

                                -- CONFIRMED → закрываем CONFIRMED того же сегмента
                                WHEN m.draft_status = false
                                     AND tm.draft_status = false
                                     AND m.seg_from IS NOT NULL
                                     AND tm.actual_from = m.seg_from
                                     AND tm.actual_to = CASE
                                         WHEN m.actual_from > m.seg_from
                                         THEN m.actual_from
                                         ELSE m.seg_to
                                     END
                                THEN c.ts_now

                                ELSE tm.closed_at
                            END
                        FROM matched m
                        CROSS JOIN const c
                        WHERE tm.object_class = m.object_class
                          AND tm.global_id = m.global_id
                          AND tm.closed_at = c.tech_inf
                          AND (
                              (m.draft_status = true AND tm.draft_status = true)
                              OR
                              (m.draft_status = false AND tm.draft_status = true)
                              OR
                              (m.draft_status = false
                               AND tm.draft_status = false
                               AND m.seg_from IS NOT NULL
                               AND tm.actual_from = m.seg_from)
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
                            m.id, m.object_class, m.global_id,
                            m.actual_from, c.biz_inf,
                            m.draft_status,
                            m.revision, m.version,
                            c.ts_now, c.tech_inf
                        FROM matched m
                        CROSS JOIN const c
                        RETURNING id
                    )
                    SELECT COUNT(*) FROM ins
                    """;

            try (PreparedStatement ps = con.prepareStatement(mainSql);
                 var rs = ps.executeQuery()) {
                return rs.next() ? rs.getInt(1) : 0;
            }
        });
    }

    /**
     * COPY потоковый — пишем построчно в PGCopyOutputStream,
     * не накапливая весь буфер в памяти.
     */
    private void copyFxSpotForwardData(List<ObjectRequest> request) {
        jdbcTemplate.execute((ConnectionCallback<Void>) con -> {
            PGConnection pgConn = con.unwrap(PGConnection.class);

            String copySql = "COPY fx_spot_forward_data (id, content, created_at) "
                    + "FROM STDIN WITH (FORMAT csv, DELIMITER E'\\t', QUOTE E'\\x01')";

            Timestamp now = Timestamp.valueOf(LocalDateTime.now());

            try (var out = new PGCopyOutputStream(pgConn, copySql)) {
                for (ObjectRequest obj : request) {
                    StringBuilder line = new StringBuilder(256);
                    line.append(obj.getHeader().getId());
                    line.append('\t');
                    line.append('\u0001');
                    line.append(obj.getJsonBody());
                    line.append('\u0001');
                    line.append('\t');
                    line.append(now.toString());
                    line.append('\n');

                    out.write(line.toString().getBytes(StandardCharsets.UTF_8));
                }
            }

            return null;
        });
    }

    private void batchInsertFxSpotForwardIndex(List<ObjectRequest> request) {
        String sql = "INSERT INTO fx_spot_forward_index "
                + "(id, national_amount, national_currency, created_at) "
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

    private void batchInsertTradeIndex(List<ObjectRequest> request) {
        String sql = "INSERT INTO trade_index "
                + "(id, legal_entity_id, portfolio_id, contract_id, created_at) "
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

### Индексы для Варианта 2

```sql
-- Те же индексы что и для Варианта 1:
CREATE INDEX IF NOT EXISTS idx_trade_main_oc_gid_closed
    ON trade_main (object_class, global_id, closed_at);

-- Покрывающий (ещё важнее для Варианта 2, т.к. Hash Join
-- будет читать все подходящие строки — INCLUDE избавляет от heap lookup):
CREATE INDEX IF NOT EXISTS idx_trade_main_oc_gid_closed_covering
    ON trade_main (object_class, global_id, closed_at)
    INCLUDE (actual_from, actual_to, draft_status);

-- Для проверки блокировок:
CREATE INDEX IF NOT EXISTS idx_object_lock_token_expire
    ON murex.object_lock (token, expire);

-- Дополнительно для Варианта 2: индекс на temp table не нужен,
-- т.к. ANALYZE + малый размер → PostgreSQL выберет Seq Scan + Hash Join,
-- что быстрее для батчей 1000-10000 строк.

-- Если trade_main партицирована по object_class:
-- убедитесь что индекс создан на КАЖДОЙ партиции (обычно автоматически).
```

---

# Сравнительная таблица

| Аспект | Вариант 1 (UNNEST) | Вариант 2 (TEMP TABLE) |
|---|---|---|
| **Планировщик** | Не знает размер UNNEST, может выбрать Nested Loops | ANALYZE даёт точную статистику → Hash Join |
| **Батч 100-500** | Быстрее (нет overhead на CREATE + ANALYZE) | Overhead ~2-5ms на создание таблицы |
| **Батч 1000-10000** | Может деградировать из-за Nested Loops | **Стабильно быстрый** благодаря Hash Join |
| **Код** | Проще, один запрос | Сложнее, но предсказуемее |
| **Рекомендация** | Батчи < 500 | **Батчи ≥ 500** |
