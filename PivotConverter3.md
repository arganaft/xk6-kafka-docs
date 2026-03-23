Понял проблему. Разные подписчики одного SQL-запроса могут иметь разные конфиги (например, group-by vs pivot, которые генерируют одинаковый SQL с 
GROUP BY n+x
), поэтому нужно:

Читать
ResultSet
один раз в память
Для каждого подписчика вызывать свою фабрику по его персональному конфигу


Ключевое изменение в архитектуре
SQL одинаковый
        ┌──────────────────────────┐
        │  GROUP BY a, b, c, d     │  ← один запрос, один ResultSet
        └──────────┬───────────────┘
                   │  читаем 1 раз → columns + rows (in-memory)
                   │
        ┌──────────┴───────────────┐
        │  для КАЖДОГО подписчика  │
        │  своя фабрика по config  │
        ├──────────────────────────┤
        │ subscriber A: pivot      │ → PivotFactory
        │ subscriber B: group-by   │ → GroupByFactory
        └──────────────────────────┘
1. 
CalciteJsonEngine
 — без изменений, возвращает 
ResultSet

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

    public ResultSet executeQuery(String sql) throws SQLException {
        log.info("Executing SQL: {}", sql);
        Statement statement = calciteConnection.createStatement();
        return statement.executeQuery(sql);
    }
}

2. 
QueryData
 — контейнер для прочитанных данных


package com.websocket.trade.calcite.model;

import java.util.List;
import java.util.Map;

/**
 * Данные, извлечённые из ResultSet один раз и хранимые в памяти.
 * Позволяет переиспользовать результат для нескольких подписчиков.
 */
public record QueryData(
        List<String> columns,
        List<Map<String, Object>> rows
) {}

3. 
ResultSetExtractor
 — утилита чтения 
ResultSet
 в 
QueryData


package com.websocket.trade.calcite;

import com.websocket.trade.calcite.model.QueryData;
import org.springframework.stereotype.Component;

import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.util.*;

@Component
public class ResultSetExtractor {

    /**
     * Читает весь ResultSet в память и возвращает QueryData.
     * После вызова ResultSet полностью consumed, но НЕ закрыт.
     */
    public QueryData extract(ResultSet rs) throws SQLException {
        ResultSetMetaData metaData = rs.getMetaData();
        int columnCount = metaData.getColumnCount();

        List<String> columns = new ArrayList<>(columnCount);
        for (int i = 1; i <= columnCount; i++) {
            columns.add(metaData.getColumnLabel(i));
        }

        List<Map<String, Object>> rows = new ArrayList<>();
        while (rs.next()) {
            Map<String, Object> row = new LinkedHashMap<>(columnCount);
            for (int i = 1; i <= columnCount; i++) {
                row.put(columns.get(i - 1), rs.getObject(i));
            }
            rows.add(row);
        }

        return new QueryData(columns, rows);
    }
}

4. Интерфейс 
QueryResponseFactory
 — принимает 
QueryData
, а не 
ResultSet

package com.websocket.trade.calcite.factory;

import com.websocket.trade.calcite.model.QueryData;
import com.websocket.trade.calcite.model.QueryResponse;
import com.websocket.trade.model.SessionRequest;

public interface QueryResponseFactory {

    boolean supports(SessionRequest sessionRequest);

    /**
     * Создаёт QueryResponse из уже прочитанных данных и конфигурации клиента.
     */
    QueryResponse create(QueryData data, SessionRequest sessionRequest);
}

5. 
AbstractQueryResponseFactory
 — общие утилиты для фабрик

 package com.websocket.trade.calcite.factory;

import com.fasterxml.jackson.databind.JsonNode;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

public abstract class AbstractQueryResponseFactory implements QueryResponseFactory {

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
     * Одно поле  → String "group-fieldKey-value"
     * Несколько  → List<String> ["group-fieldKey1-value1", "group-fieldKey2-value2"]
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

6. 
SimpleQueryResponseFactory


package com.websocket.trade.calcite.factory;

import com.fasterxml.jackson.databind.JsonNode;
import com.websocket.trade.calcite.model.QueryData;
import com.websocket.trade.calcite.model.QueryResponse;
import com.websocket.trade.model.SessionRequest;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;

@Component
@Order(3)
public class SimpleQueryResponseFactory extends AbstractQueryResponseFactory {

    @Override
    public boolean supports(SessionRequest sessionRequest) {
        JsonNode config = sessionRequest.config();
        JsonNode rowGroupColumns = config.get("rowGroupColumns");
        return rowGroupColumns == null || rowGroupColumns.isEmpty();
    }

    @Override
    public QueryResponse create(QueryData data, SessionRequest sessionRequest) {
        return QueryResponse.builder()
                .columnDefs(data.columns())
                .rows(data.rows())
                .success(true)
                .lastRow(data.rows().size())
                .build();
    }
}

7. 
GroupByQueryResponseFactory
package com.websocket.trade.calcite.factory;

import com.fasterxml.jackson.databind.JsonNode;
import com.websocket.trade.calcite.model.QueryData;
import com.websocket.trade.calcite.model.QueryResponse;
import com.websocket.trade.model.SessionRequest;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;

import java.util.*;

@Component
@Order(2)
public class GroupByQueryResponseFactory extends AbstractQueryResponseFactory {

    @Override
    public boolean supports(SessionRequest sessionRequest) {
        JsonNode config = sessionRequest.config();
        JsonNode rowGroupColumns = config.get("rowGroupColumns");
        boolean hasPivot = isPivotActive(config);
        return rowGroupColumns != null && !rowGroupColumns.isEmpty() && !hasPivot;
    }

    @Override
    public QueryResponse create(QueryData data, SessionRequest sessionRequest) {
        JsonNode config = sessionRequest.config();
        List<String> groupFieldKeys = extractFieldKeys(config.get("rowGroupColumns"));

        List<Map<String, Object>> modifiedRows = new ArrayList<>();
        for (Map<String, Object> row : data.rows()) {
            Map<String, Object> modifiedRow = new LinkedHashMap<>(row);
            modifiedRow.put("__agGroup", true);
            modifiedRow.put("groupId", buildGroupId(groupFieldKeys, row));
            modifiedRows.add(modifiedRow);
        }

        return QueryResponse.builder()
                .columnDefs(data.columns())
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

8. 
PivotQueryResponseFactory
package com.websocket.trade.calcite.factory;

import com.fasterxml.jackson.databind.JsonNode;
import com.websocket.trade.calcite.model.QueryData;
import com.websocket.trade.calcite.model.QueryResponse;
import com.websocket.trade.model.SessionRequest;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;

import java.util.*;
import java.util.stream.Collectors;

@Component
@Order(1)
public class PivotQueryResponseFactory extends AbstractQueryResponseFactory {

    @Override
    public boolean supports(SessionRequest sessionRequest) {
        JsonNode config = sessionRequest.config();
        boolean pivotMode = config.has("pivotMode") && config.get("pivotMode").asBoolean();
        JsonNode pivotColumns = config.get("pivotColumns");
        return pivotMode && pivotColumns != null && !pivotColumns.isEmpty();
    }

    @Override
    public QueryResponse create(QueryData data, SessionRequest sessionRequest) {
        JsonNode config = sessionRequest.config();
        List<String> rowGroupFieldKeys = extractFieldKeys(config.get("rowGroupColumns"));
        List<String> pivotFieldKeys = extractFieldKeys(config.get("pivotColumns"));
        List<String> valueFieldKeys = extractFieldKeys(config.get("valueColumns"));

        // ── 1. Собираем уникальные pivot-ключи (сохраняя порядок появления) ──
        Set<String> uniquePivotKeys = new LinkedHashSet<>();
        for (Map<String, Object> row : data.rows()) {
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
        //   В SQL результате строки приходят с GROUP BY (rowGroup + pivot),
        //   нужно свернуть в строки только по rowGroup, раскидав pivot-значения по колонкам
        Map<String, List<Map<String, Object>>> grouped = new LinkedHashMap<>();
        for (Map<String, Object> row : data.rows()) {
            String groupKey = rowGroupFieldKeys.stream()
                    .map(k -> String.valueOf(row.get(k)))
                    .collect(Collectors.joining("|"));
            grouped.computeIfAbsent(groupKey, k -> new ArrayList<>()).add(row);
        }

        // ── 5. Строим результирующие строки ──
        List<Map<String, Object>> resultRows = new ArrayList<>();
        for (List<Map<String, Object>> groupRows : grouped.values()) {
            Map<String, Object> resultRow = new LinkedHashMap<>();

            // Значения rowGroupColumns берём из первой строки группы
            Map<String, Object> firstRow = groupRows.get(0);
            for (String rgk : rowGroupFieldKeys) {
                resultRow.put(rgk, firstRow.get(rgk));
            }

            // __agGroup / groupId
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

9. 
QueryResponseFactoryDispatcher
 — принимает 
QueryData

package com.websocket.trade.calcite;

import com.websocket.trade.calcite.factory.QueryResponseFactory;
import com.websocket.trade.calcite.model.QueryData;
import com.websocket.trade.calcite.model.QueryResponse;
import com.websocket.trade.model.SessionRequest;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Service;

import java.util.List;

@Service
@Slf4j
public class QueryResponseFactoryDispatcher {

    private final List<QueryResponseFactory> factories;

    public QueryResponseFactoryDispatcher(List<QueryResponseFactory> factories) {
        this.factories = factories;
        log.info("Registered {} QueryResponseFactory implementations:", factories.size());
        factories.forEach(f -> log.info("  • {}", f.getClass().getSimpleName()));
    }

    /**
     * Выбирает подходящую фабрику по конфигу подписчика
     * и создаёт QueryResponse из уже прочитанных данных.
     */
    public QueryResponse createQueryResponse(QueryData data, SessionRequest sessionRequest) {
        for (QueryResponseFactory factory : factories) {
            if (factory.supports(sessionRequest)) {
                log.debug("Using factory {} for request {}",
                        factory.getClass().getSimpleName(), sessionRequest.requestId());
                return factory.create(data, sessionRequest);
            }
        }
        throw new IllegalStateException(
                "No QueryResponseFactory found for request: " + sessionRequest.requestId());
    }
}

10. Обновлённый 
TradeService

package com.websocket.trade;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.websocket.trade.calcite.CalciteJsonEngine;
import com.websocket.trade.calcite.QueryResponseFactoryDispatcher;
import com.websocket.trade.calcite.ResultSetExtractor;
import com.websocket.trade.calcite.model.QueryData;
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
    private final ResultSetExtractor resultSetExtractor;
    private final QueryResponseFactoryDispatcher responseFactoryDispatcher;
    private final ObjectMapper objectMapper;
    private final StreamViewConfigToSqlConverter streamViewConfigToSqlConverter;

    // Map<SQLQuery, List<SessionRequest>>
    private final Map<String, List<SessionRequest>> clientSubscriptions = new ConcurrentHashMap<>();

    @Autowired
    public TradeService(MessageSender messageSender,
                        CalciteJsonEngine calciteEngine,
                        ResultSetExtractor resultSetExtractor,
                        QueryResponseFactoryDispatcher responseFactoryDispatcher,
                        ObjectMapper objectMapper,
                        StreamViewConfigToSqlConverter streamViewConfigToSqlConverter) {
        this.responseSender = messageSender;
        this.calciteEngine = calciteEngine;
        this.resultSetExtractor = resultSetExtractor;
        this.responseFactoryDispatcher = responseFactoryDispatcher;
        this.objectMapper = objectMapper;
        this.streamViewConfigToSqlConverter = streamViewConfigToSqlConverter;
    }

    public void addSubscription(JsonNode data, String clientId) throws JsonProcessingException {
        String requestId = data.get("requestId").asText();

        String sqlQuery = streamViewConfigToSqlConverter.convert(data);
        log.info("SQLQuery: {}", sqlQuery);
        clientSubscriptions
                .computeIfAbsent(sqlQuery, k -> new ArrayList<>())
                .add(new SessionRequest(clientId, requestId, data));

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
     * Обработка входящего потока данных:
     * 1. Загружаем JSON в Calcite
     * 2. Для каждого уникального SQL — выполняем запрос ОДИН раз, читаем данные в память
     * 3. Для КАЖДОГО подписчика — вызываем свою фабрику по его персональному конфигу
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

            // ── 1. Выполняем SQL один раз, читаем данные в память ──
            QueryData queryData;
            try {
                queryData = executeAndExtract(sqlQuery);
            } catch (SQLException e) {
                log.error("SQL execution error for query [{}]: {}", sqlQuery, e.getMessage(), e);
                sendErrorToAll(subscribers, e.getMessage());
                continue;
            }

            // ── 2. Для КАЖДОГО подписчика — своя фабрика по его конфигу ──
            for (SessionRequest sessionRequest : subscribers) {
                try {
                    QueryResponse response = responseFactoryDispatcher
                            .createQueryResponse(queryData, sessionRequest);
                    response.setType("ReceiveData");
                    sendResponse(sessionRequest, response);
                } catch (Exception e) {
                    log.error("Error building response for session {} request {}: {}",
                            sessionRequest.clientId(), sessionRequest.requestId(), e.getMessage(), e);
                    sendError(sessionRequest, e.getMessage());
                }
            }
        }
    }

    // ─── private helpers ────────────────────────────────────────────────

    /**
     * Выполняет SQL, читает ResultSet целиком в QueryData, закрывает ресурсы.
     */
    private QueryData executeAndExtract(String sqlQuery) throws SQLException {
        ResultSet rs = null;
        Statement stmt = null;
        try {
            rs = calciteEngine.executeQuery(sqlQuery);
            stmt = rs.getStatement();
            return resultSetExtractor.extract(rs);
        } finally {
            closeQuietly(rs, stmt);
        }
    }

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

    private void sendError(SessionRequest sr, String errorMessage) {
        try {
            QueryResponse errorResponse = QueryResponse.builder()
                    .type("ReceiveData")
                    .success(false)
                    .error(String.format("Error: %s", errorMessage))
                    .requestId(sr.requestId())
                    .build();
            responseSender.sendToSession(sr.clientId(), objectMapper.writeValueAsString(errorResponse));
        } catch (JsonProcessingException ex) {
            responseSender.sendToSession(sr.clientId(), "Error on response serialization");
        }
    }

    private void sendErrorToAll(List<SessionRequest> subscribers, String errorMessage) {
        for (SessionRequest sr : subscribers) {
            sendError(sr, String.format("SQL execution error: %s", errorMessage));
        }
    }

    private void closeQuietly(ResultSet rs, Statement stmt) {
        if (rs != null) {
            try { rs.close(); } catch (SQLException ignored) {}
        }
        if (stmt != null) {
            try { stmt.close(); } catch (SQLException ignored) {}
        }
    }

    private void loadJsonToCalcite(String json) {
        // существующая реализация
    }
}

Итоговая диаграмма потока данных

processIncomingData(json)
         │
         ▼
  ┌─────────────────────────────────────────────┐
  │  for each unique SQL query:                 │
  │                                             │
  │  executeAndExtract(sql)                     │
  │    ├─ CalciteJsonEngine.executeQuery(sql)   │  → ResultSet
  │    ├─ ResultSetExtractor.extract(rs)        │  → QueryData (columns + rows)
  │    └─ close(rs, stmt)                       │
  │                                             │
  │  ┌────────────────────────────────────────┐ │
  │  │ for EACH subscriber of this SQL:       │ │
  │  │                                        │ │
  │  │  dispatcher.createQueryResponse(       │ │
  │  │      queryData,        ← одни и те же  │ │
  │  │      sessionRequest    ← СВОЙ конфиг   │ │
  │  │  )                                     │ │
  │  │       │                                │ │
  │  │       ▼                                │ │
  │  │  factory.supports(sessionRequest)?     │ │
  │  │    @Order(1) PivotFactory    ──────┐   │ │
  │  │    @Order(2) GroupByFactory  ──────┤   │ │
  │  │    @Order(3) SimpleFactory   ──────┘   │ │
  │  │       │                                │ │
  │  │       ▼                                │ │
  │  │  QueryResponse (уникальный для        │ │
  │  │   конфига подписчика)                  │ │
  │  └────────────────────────────────────────┘ │
  └─────────────────────────────────────────────┘

  Ключевое отличие от предыдущей версии:


Аспект	Было	Стало
Данные из ResultSet	Читались внутри фабрики	Читаются один раз в 
QueryData
 через 
ResultSetExtractor
Фабрика получает	
ResultSet
QueryData
 (уже в памяти, переиспользуемый)
Выбор фабрики	По первому подписчику SQL-группы	По каждому подписчику индивидуально
Один SQL → разные конфиги	Невозможно (баг)	Работает: pivot и group-by подписчики одного SQL получают разные ответы
