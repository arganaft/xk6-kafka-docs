Давайте проведём рефакторинг. Я распишу каждый класс/интерфейс, который нужно создать или изменить.
1. Выносим 
SessionRequest
 в отдельный файл

com/websocket/trade/model/SessionRequest.java
package com.websocket.trade.model;

import com.fasterxml.jackson.databind.JsonNode;

public record SessionRequest(
        String clientId,
        String requestId,
        JsonNode config) {
}

2. Упрощаем 
CalciteJsonEngine
 — возвращаем только 
ResultSet

com/websocket/trade/calcite/CalciteJsonEngine.java

package com.websocket.trade.calcite;

import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Service;

import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;

@Service
@Slf4j
public class CalciteJsonEngine {

    private final Connection calciteConnection;

    public CalciteJsonEngine(Connection calciteConnection) {
        this.calciteConnection = calciteConnection;
    }

    /**
     * Выполняет SQL-запрос и возвращает открытый ResultSet.
     * Вызывающая сторона ОБЯЗАНА закрыть ResultSet и его Statement после использования:
     * <pre>
     *   ResultSet rs = engine.executeQuery(sql);
     *   try { ... } finally {
     *       Statement st = rs.getStatement();
     *       rs.close();
     *       if (st != null) st.close();
     *   }
     * </pre>
     */
    public ResultSet executeQuery(String sql) throws SQLException {
        log.info("Executing SQL: {}", sql);
        Statement statement = calciteConnection.createStatement();
        return statement.executeQuery(sql);
    }
}

3. Интерфейс 
QueryResponseFactory

com/websocket/trade/calcite/factory/QueryResponseFactory.java

package com.websocket.trade.calcite.factory;

import com.websocket.trade.calcite.model.QueryResponse;
import com.websocket.trade.model.SessionRequest;

import java.sql.ResultSet;
import java.sql.SQLException;

public interface QueryResponseFactory {

    /**
     * Определяет, подходит ли эта фабрика для данного запроса.
     */
    boolean supports(SessionRequest sessionRequest);

    /**
     * Создаёт QueryResponse из открытого ResultSet и конфигурации клиента.
     * Фабрика НЕ закрывает ResultSet — это ответственность вызывающего кода.
     */
    QueryResponse create(ResultSet rs, SessionRequest sessionRequest) throws SQLException;
}

4. Абстрактный базовый класс с утилитами чтения 
ResultSet

com/websocket/trade/calcite/factory/AbstractQueryResponseFactory.java


package com.websocket.trade.calcite.factory;

import com.fasterxml.jackson.databind.JsonNode;

import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.util.*;

public abstract class AbstractQueryResponseFactory implements QueryResponseFactory {

    protected List<String> extractColumns(ResultSet rs) throws SQLException {
        ResultSetMetaData metaData = rs.getMetaData();
        int columnCount = metaData.getColumnCount();
        List<String> columns = new ArrayList<>(columnCount);
        for (int i = 1; i <= columnCount; i++) {
            columns.add(metaData.getColumnLabel(i));
        }
        return columns;
    }

    protected List<Map<String, Object>> extractRows(ResultSet rs, List<String> columns) throws SQLException {
        List<Map<String, Object>> rows = new ArrayList<>();
        while (rs.next()) {
            Map<String, Object> row = new LinkedHashMap<>(columns.size());
            for (int i = 1; i <= columns.size(); i++) {
                row.put(columns.get(i - 1), rs.getObject(i));
            }
            rows.add(row);
        }
        return rows;
    }

    /**
     * Извлекает список fieldKey из JSON-массива (rowGroupColumns / pivotColumns / valueColumns).
     */
    protected List<String> extractFieldKeys(JsonNode arrayNode) {
        List<String> keys = new ArrayList<>();
        if (arrayNode != null && arrayNode.isArray()) {
            for (JsonNode node : arrayNode) {
                keys.add(node.get("fieldKey").asText());
            }
        }
        return keys;
    }

    /**
     * Формирует значение groupId на основе полей группировки и значений из строки.
     * Если одно поле — возвращает String, если несколько — List<String>.
     */
    protected Object buildGroupId(List<String> groupFieldKeys, Map<String, Object> row) {
        if (groupFieldKeys.size() == 1) {
            String fieldKey = groupFieldKeys.get(0);
            return String.format("group-%s-%s", fieldKey, row.get(fieldKey));
        }
        List<String> groupIds = new ArrayList<>();
        for (String fieldKey : groupFieldKeys) {
            groupIds.add(String.format("group-%s-%s", fieldKey, row.get(fieldKey)));
        }
        return groupIds;
    }
}

5. 
SimpleQueryResponseFactory
 — плоский список без группировок

com/websocket/trade/calcite/factory/SimpleQueryResponseFactory.java



package com.websocket.trade.calcite.factory;

import com.fasterxml.jackson.databind.JsonNode;
import com.websocket.trade.calcite.model.QueryResponse;
import com.websocket.trade.model.SessionRequest;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.List;
import java.util.Map;

@Component
@Order(3) // самый низкий приоритет — фоллбэк
public class SimpleQueryResponseFactory extends AbstractQueryResponseFactory {

    @Override
    public boolean supports(SessionRequest sessionRequest) {
        JsonNode config = sessionRequest.config();
        JsonNode rowGroupColumns = config.get("rowGroupColumns");
        // Подходит, если группировки нет
        return rowGroupColumns == null || rowGroupColumns.isEmpty();
    }

    @Override
    public QueryResponse create(ResultSet rs, SessionRequest sessionRequest) throws SQLException {
        List<String> columns = extractColumns(rs);
        List<Map<String, Object>> rows = extractRows(rs, columns);

        return QueryResponse.builder()
                .columnDefs(columns)
                .rows(rows)
                .success(true)
                .lastRow(rows.size())
                .build();
    }
}

6. 
GroupByQueryResponseFactory
 — группировка без пивота

com/websocket/trade/calcite/factory/GroupByQueryResponseFactory.java


package com.websocket.trade.calcite.factory;

import com.fasterxml.jackson.databind.JsonNode;
import com.websocket.trade.calcite.model.QueryResponse;
import com.websocket.trade.model.SessionRequest;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.*;

@Component
@Order(2)
public class GroupByQueryResponseFactory extends AbstractQueryResponseFactory {

    @Override
    public boolean supports(SessionRequest sessionRequest) {
        JsonNode config = sessionRequest.config();
        JsonNode rowGroupColumns = config.get("rowGroupColumns");
        boolean hasPivot = isPivotActive(config);
        // Группировка есть, но пивот НЕ активен
        return rowGroupColumns != null && !rowGroupColumns.isEmpty() && !hasPivot;
    }

    @Override
    public QueryResponse create(ResultSet rs, SessionRequest sessionRequest) throws SQLException {
        List<String> columns = extractColumns(rs);
        List<Map<String, Object>> rows = extractRows(rs, columns);

        JsonNode config = sessionRequest.config();
        List<String> groupFieldKeys = extractFieldKeys(config.get("rowGroupColumns"));

        List<Map<String, Object>> modifiedRows = new ArrayList<>();
        for (Map<String, Object> row : rows) {
            Map<String, Object> modifiedRow = new LinkedHashMap<>(row);
            modifiedRow.put("__agGroup", true);
            modifiedRow.put("groupId", buildGroupId(groupFieldKeys, row));
            modifiedRows.add(modifiedRow);
        }

        return QueryResponse.builder()
                .columnDefs(columns)
                .rows(modifiedRows)
                .success(true)
                .lastRow(modifiedRows.size())
                .build();
    }

    private boolean isPivotActive(JsonNode config) {
        boolean pivotMode = config.has("pivotMode") && config.get("pivotMode").asBoolean();
        JsonNode pivotColumns = config.get("pivotColumns");
        return pivotMode && pivotColumns != null && !pivotColumns.isEmpty();
    }
}

7. 
PivotQueryResponseFactory
 — сводная таблица

com/websocket/trade/calcite/factory/PivotQueryResponseFactory.java

package com.websocket.trade.calcite.factory;

import com.fasterxml.jackson.databind.JsonNode;
import com.websocket.trade.calcite.model.QueryResponse;
import com.websocket.trade.model.SessionRequest;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.*;
import java.util.stream.Collectors;

@Component
@Order(1) // наивысший приоритет
public class PivotQueryResponseFactory extends AbstractQueryResponseFactory {

    @Override
    public boolean supports(SessionRequest sessionRequest) {
        JsonNode config = sessionRequest.config();
        boolean pivotMode = config.has("pivotMode") && config.get("pivotMode").asBoolean();
        JsonNode pivotColumns = config.get("pivotColumns");
        return pivotMode && pivotColumns != null && !pivotColumns.isEmpty();
    }

    @Override
    public QueryResponse create(ResultSet rs, SessionRequest sessionRequest) throws SQLException {
        List<String> columns = extractColumns(rs);
        List<Map<String, Object>> rows = extractRows(rs, columns);

        JsonNode config = sessionRequest.config();
        List<String> rowGroupFieldKeys = extractFieldKeys(config.get("rowGroupColumns"));
        List<String> pivotFieldKeys = extractFieldKeys(config.get("pivotColumns"));
        List<String> valueFieldKeys = extractFieldKeys(config.get("valueColumns"));

        // ── 1. Собираем уникальные pivot-ключи (сохраняя порядок появления) ──
        Set<String> uniquePivotKeys = new LinkedHashSet<>();
        for (Map<String, Object> row : rows) {
            uniquePivotKeys.add(buildPivotKey(pivotFieldKeys, row));
        }

        // ── 2. Формируем имена pivot-колонок ──
        List<String> pivotDefs = new ArrayList<>();
        for (String pivotKey : uniquePivotKeys) {
            for (String valueField : valueFieldKeys) {
                pivotDefs.add(pivotKey + " | " + valueField);
            }
        }

        // ── 3. Итоговые columnDefs = rowGroupColumns + pivotDefs ──
        List<String> resultColumnDefs = new ArrayList<>(rowGroupFieldKeys);
        resultColumnDefs.addAll(pivotDefs);

        // ── 4. Группируем строки по rowGroupColumns ──
        //   Ключ группы — конкатенация значений rowGroupColumns
        Map<String, List<Map<String, Object>>> grouped = new LinkedHashMap<>();
        for (Map<String, Object> row : rows) {
            String groupKey = rowGroupFieldKeys.stream()
                    .map(k -> String.valueOf(row.get(k)))
                    .collect(Collectors.joining("|"));
            grouped.computeIfAbsent(groupKey, k -> new ArrayList<>()).add(row);
        }

        // ── 5. Строим результирующие строки ──
        List<Map<String, Object>> resultRows = new ArrayList<>();
        for (List<Map<String, Object>> groupRows : grouped.values()) {
            Map<String, Object> resultRow = new LinkedHashMap<>();

            // значения rowGroupColumns берём из первой строки группы
            Map<String, Object> firstRow = groupRows.get(0);
            for (String rgk : rowGroupFieldKeys) {
                resultRow.put(rgk, firstRow.get(rgk));
            }

            // __agGroup / groupId — аналогично GroupBy
            resultRow.put("__agGroup", true);
            resultRow.put("groupId", buildGroupId(rowGroupFieldKeys, firstRow));

            // Раскладываем агрегаты по pivot-колонкам
            for (Map<String, Object> row : groupRows) {
                String pivotKey = buildPivotKey(pivotFieldKeys, row);
                for (String valueField : valueFieldKeys) {
                    String columnName = pivotKey + " | " + valueField;
                    resultRow.put(columnName, row.get(valueField));
                }
            }

            resultRows.add(resultRow);
        }

        return QueryResponse.builder()
                .columnDefs(resultColumnDefs)
                .pivotDefs(pivotDefs)
                .rows(resultRows)
                .success(true)
                .lastRow(resultRows.size())
                .build();
    }

    /**
     * Формирует pivot-ключ из значений pivot-колонок строки.
     * Одна pivot-колонка  → "1"
     * Несколько            → "1_active"
     */
    private String buildPivotKey(List<String> pivotFieldKeys, Map<String, Object> row) {
        return pivotFieldKeys.stream()
                .map(pk -> String.valueOf(row.get(pk)))
                .collect(Collectors.joining("_"));
    }
}

8. 
QueryResponseFactoryDispatcher
 — диспетчер

com/websocket/trade/calcite/QueryResponseFactoryDispatcher.java



package com.websocket.trade.calcite;

import com.websocket.trade.calcite.factory.QueryResponseFactory;
import com.websocket.trade.calcite.model.QueryResponse;
import com.websocket.trade.model.SessionRequest;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Service;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.List;

@Service
@Slf4j
public class QueryResponseFactoryDispatcher {

    private final List<QueryResponseFactory> factories; // Spring внедряет в порядке @Order

    public QueryResponseFactoryDispatcher(List<QueryResponseFactory> factories) {
        this.factories = factories;
        log.info("Registered {} QueryResponseFactory implementations:", factories.size());
        factories.forEach(f -> log.info("  • {}", f.getClass().getSimpleName()));
    }

    /**
     * Выбирает подходящую фабрику и создаёт QueryResponse.
     *
     * @param rs             открытый ResultSet (НЕ закрывается диспетчером)
     * @param sessionRequest конфигурация клиентской подписки
     */
    public QueryResponse createQueryResponse(ResultSet rs, SessionRequest sessionRequest) throws SQLException {
        for (QueryResponseFactory factory : factories) {
            if (factory.supports(sessionRequest)) {
                log.debug("Using factory: {}", factory.getClass().getSimpleName());
                return factory.create(rs, sessionRequest);
            }
        }
        throw new IllegalStateException(
                "No QueryResponseFactory found for request: " + sessionRequest.requestId());
    }
}

9. Обновлённый 
TradeService

com/websocket/trade/TradeService.java


package com.websocket.trade;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.websocket.trade.calcite.CalciteJsonEngine;
import com.websocket.trade.calcite.QueryResponseFactoryDispatcher;
import com.websocket.trade.calcite.model.QueryResponse;
import com.websocket.trade.model.SessionRequest;
import com.websocket.trade.websocket.ConfigurationUpdatedEvent;
import com.websocket.trade.websocket.MessageSender;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

@Service
@Slf4j
public class TradeService {

    private final MessageSender responseSender;
    private final CalciteJsonEngine calciteEngine;
    private final ObjectMapper objectMapper;
    private final StreamViewConfigToSqlConverter streamViewConfigToSqlConverter;
    private final QueryResponseFactoryDispatcher responseFactoryDispatcher;

    // Map<SQLQuery, List<SessionRequest>>
    private final Map<String, List<SessionRequest>> clientSubscriptions = new ConcurrentHashMap<>();

    @Autowired
    public TradeService(MessageSender messageSender,
                        CalciteJsonEngine calciteEngine,
                        ObjectMapper objectMapper,
                        StreamViewConfigToSqlConverter streamViewConfigToSqlConverter,
                        QueryResponseFactoryDispatcher responseFactoryDispatcher) {
        this.responseSender = messageSender;
        this.calciteEngine = calciteEngine;
        this.objectMapper = objectMapper;
        this.streamViewConfigToSqlConverter = streamViewConfigToSqlConverter;
        this.responseFactoryDispatcher = responseFactoryDispatcher;
    }

    public void addSubscription(JsonNode data, String clientId) throws JsonProcessingException {
        String requestId = data.get("requestId").asText();

        String sqlQuery = streamViewConfigToSqlConverter.convert(data);
        log.info("SQLQuery: {}", sqlQuery);
        clientSubscriptions
                .computeIfAbsent(sqlQuery, k -> new ArrayList<>())
                .add(new SessionRequest(clientId, requestId, data));

        // Отправляем подтверждение
        ConfigurationUpdatedEvent event = new ConfigurationUpdatedEvent(
                data,
                Instant.now().toString()
        );
        responseSender.sendToSession(clientId, event);
    }

    public void removeSession(String sessionId) {
        clientSubscriptions.values().forEach(sessions ->
                sessions.removeIf(session -> session.clientId().equals(sessionId)));
    }

    /**
     * Обработка входящего потока данных (от Mock или Ingest):
     * загружаем JSON в Calcite, выполняем все подписанные SQL-запросы,
     * формируем ответ через диспетчер фабрик и рассылаем подписчикам.
     */
    public void processIncomingData(String json) {
        loadJsonToCalcite(json);
        log.debug("Generated JSON: {}", json);

        for (Map.Entry<String, List<SessionRequest>> entry : clientSubscriptions.entrySet()) {
            String sqlQuery = entry.getKey();
            List<SessionRequest> subscribers = entry.getValue();

            if (subscribers.isEmpty()) {
                continue;
            }

            ResultSet rs = null;
            Statement stmt = null;
            try {
                rs = calciteEngine.executeQuery(sqlQuery);
                stmt = rs.getStatement();

                // Берём первого подписчика для определения типа ответа —
                // все подписчики одного SQL-запроса имеют одинаковую конфигурацию.
                SessionRequest representative = subscribers.get(0);
                QueryResponse response = responseFactoryDispatcher.createQueryResponse(rs, representative);
                response.setType("ReceiveData");

                // Рассылаем ответ каждому подписчику со своим requestId
                for (SessionRequest sessionRequest : subscribers) {
                    sendResponse(sessionRequest, response);
                }

            } catch (SQLException e) {
                log.error("SQL execution error for query [{}]: {}", sqlQuery, e.getMessage(), e);
                sendErrorToAll(subscribers, e.getMessage());
            } finally {
                closeQuietly(rs, stmt);
            }
        }
    }

    // ─── private helpers ────────────────────────────────────────────────

    private void sendResponse(SessionRequest sessionRequest, QueryResponse response) {
        try {
            QueryResponse personalised = response.withRequestId(sessionRequest.requestId());
            String responseJson = objectMapper.writeValueAsString(personalised);
            responseSender.sendToSession(sessionRequest.clientId(), responseJson);
        } catch (JsonProcessingException e) {
            log.error("Serialization error for session {}: {}", sessionRequest.clientId(), e.getMessage());
            responseSender.sendToSession(sessionRequest.clientId(), "Error on response serialization");
        }
    }

    private void sendErrorToAll(List<SessionRequest> subscribers, String errorMessage) {
        for (SessionRequest sr : subscribers) {
            try {
                QueryResponse errorResponse = QueryResponse.builder()
                        .type("ReceiveData")
                        .success(false)
                        .error(String.format("SQL execution error: %s", errorMessage))
                        .requestId(sr.requestId())
                        .build();
                String json = objectMapper.writeValueAsString(errorResponse);
                responseSender.sendToSession(sr.clientId(), json);
            } catch (JsonProcessingException ex) {
                responseSender.sendToSession(sr.clientId(), "Error on response serialization");
            }
        }
    }

    private void closeQuietly(ResultSet rs, Statement stmt) {
        if (rs != null) {
            try { rs.close(); } catch (SQLException ignored) { }
        }
        if (stmt != null) {
            try { stmt.close(); } catch (SQLException ignored) { }
        }
    }

    private void loadJsonToCalcite(String json) {
        // ваша существующая реализация
    }
}

10. 
QueryResponse
 — без изменений, для полноты

 package com.websocket.trade.calcite.model;

import com.fasterxml.jackson.annotation.JsonInclude;
import lombok.Builder;
import lombok.Data;
import lombok.With;

import java.util.List;
import java.util.Map;

@Data
@Builder
@JsonInclude(JsonInclude.Include.NON_NULL)
public class QueryResponse {
    private String type;
    private boolean success;
    private String error;
    private List<Map<String, Object>> rows;
    private int lastRow;
    @With
    private final String requestId;
    private List<String> pivotDefs;
    private List<String> columnDefs;
}

Резюме архитектуры
┌──────────────────────────────┐
                         │       TradeService            │
                         │  processIncomingData(json)    │
                         └──────┬───────────────────────┘
                                │
              1. executeQuery   │   2. createQueryResponse
         ┌──────────────────────┼──────────────────────────┐
         ▼                      ▼                          │
  CalciteJsonEngine    QueryResponseFactoryDispatcher      │
  (returns ResultSet)   │                                  │
                        ├─ @Order(1) PivotQueryResponseFactory
                        │    supports: pivotMode=true && pivotColumns≠∅
                        │
                        ├─ @Order(2) GroupByQueryResponseFactory
                        │    supports: rowGroupColumns≠∅ && !pivot
                        │
                        └─ @Order(3) SimpleQueryResponseFactory
                             supports: всё остальное (фоллбэк)

Ключевые изменения:
