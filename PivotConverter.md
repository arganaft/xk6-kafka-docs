# Pivot Converter для Apache Calcite результатов

## Концепция

Из SQL запроса с `GROUP BY legalEntityId, globalId` мы берём:
- **Строки (rows)**: первые N полей группировки (например, `legalEntityId`)
- **Колонки (columns)**: оставшиеся поля группировки (например, `globalId`)
- **Значения (values)**: агрегированные поля (`confirmedAt`, `closedAt`, `baseAmount`, `tradeDateTime`, `fxRate`)

## Классы

### PivotConfig — конфигурация

```java
package com.example.pivot;

import java.util.List;

public class PivotConfig {
    /** Поля группировки, которые станут строками */
    private List<String> rowFields;
    /** Поля группировки, которые станут колонками */
    private List<String> columnFields;
    /** Агрегированные поля (значения в ячейках) */
    private List<String> valueFields;
    /** Разделитель для составных ключей */
    private String separator = " | ";

    public PivotConfig() {}

    public PivotConfig(List<String> rowFields, List<String> columnFields, List<String> valueFields) {
        this.rowFields = rowFields;
        this.columnFields = columnFields;
        this.valueFields = valueFields;
    }

    // Getters & Setters
    public List<String> getRowFields() { return rowFields; }
    public void setRowFields(List<String> rowFields) { this.rowFields = rowFields; }
    public List<String> getColumnFields() { return columnFields; }
    public void setColumnFields(List<String> columnFields) { this.columnFields = columnFields; }
    public List<String> getValueFields() { return valueFields; }
    public void setValueFields(List<String> valueFields) { this.valueFields = valueFields; }
    public String getSeparator() { return separator; }
    public void setSeparator(String separator) { this.separator = separator; }
}
```

### PivotResult — результат

```java
package com.example.pivot;

import java.util.List;
import java.util.Map;

public class PivotResult {
    /** Названия колонок-строк (rowFields) */
    private List<String> rowHeaders;
    /** Уникальные значения колонок pivot (составные ключи columnFields) */
    private List<String> pivotColumnKeys;
    /** Названия полей значений */
    private List<String> valueFields;
    /**
     * Полные заголовки pivot-колонок: pivotColumnKey + separator + valueField
     * Например: "6111 | confirmedAt", "6111 | baseAmount", "983422 | confirmedAt" ...
     */
    private List<String> allColumnHeaders;
    /** Данные: каждая строка — Map, где ключи = rowFields + allColumnHeaders */
    private List<Map<String, Object>> rows;

    // Getters & Setters
    public List<String> getRowHeaders() { return rowHeaders; }
    public void setRowHeaders(List<String> rowHeaders) { this.rowHeaders = rowHeaders; }
    public List<String> getPivotColumnKeys() { return pivotColumnKeys; }
    public void setPivotColumnKeys(List<String> pivotColumnKeys) { this.pivotColumnKeys = pivotColumnKeys; }
    public List<String> getValueFields() { return valueFields; }
    public void setValueFields(List<String> valueFields) { this.valueFields = valueFields; }
    public List<String> getAllColumnHeaders() { return allColumnHeaders; }
    public void setAllColumnHeaders(List<String> allColumnHeaders) { this.allColumnHeaders = allColumnHeaders; }
    public List<Map<String, Object>> getRows() { return rows; }
    public void setRows(List<Map<String, Object>> rows) { this.rows = rows; }
}
```

### PivotConverter — основной конвертер

```java
package com.example.pivot;

import java.util.*;
import java.util.stream.Collectors;

public class PivotConverter {

    /**
     * Конвертирует плоский список результатов GROUP BY в pivot-таблицу.
     *
     * @param data   результат SQL-запроса: List<Map<String, Object>>
     * @param config конфигурация pivot
     * @return PivotResult с развёрнутой таблицей
     */
    public PivotResult convert(List<Map<String, Object>> data, PivotConfig config) {
        Objects.requireNonNull(data, "data must not be null");
        Objects.requireNonNull(config, "config must not be null");
        Objects.requireNonNull(config.getRowFields(), "rowFields must not be null");
        Objects.requireNonNull(config.getColumnFields(), "columnFields must not be null");
        Objects.requireNonNull(config.getValueFields(), "valueFields must not be null");

        String sep = config.getSeparator();
        List<String> rowFields = config.getRowFields();
        List<String> colFields = config.getColumnFields();
        List<String> valFields = config.getValueFields();

        // 1. Собираем уникальные pivot-ключи колонок (в порядке появления)
        LinkedHashSet<String> pivotColumnKeysSet = new LinkedHashSet<>();
        for (Map<String, Object> row : data) {
            pivotColumnKeysSet.add(buildCompositeKey(row, colFields, sep));
        }
        List<String> pivotColumnKeys = new ArrayList<>(pivotColumnKeysSet);

        // 2. Формируем полные заголовки: pivotKey + sep + valueField
        List<String> allColumnHeaders = new ArrayList<>();
        for (String pivotKey : pivotColumnKeys) {
            for (String valField : valFields) {
                allColumnHeaders.add(pivotKey + sep + valField);
            }
        }

        // 3. Группируем данные по rowKey
        //    rowKey -> (pivotColumnKey -> Map<valueField, value>)
        LinkedHashMap<String, Map<String, Map<String, Object>>> grouped = new LinkedHashMap<>();
        // Также сохраняем оригинальные значения rowFields для каждого rowKey
        LinkedHashMap<String, Map<String, Object>> rowFieldValues = new LinkedHashMap<>();

        for (Map<String, Object> row : data) {
            String rowKey = buildCompositeKey(row, rowFields, sep);
            String colKey = buildCompositeKey(row, colFields, sep);

            grouped.computeIfAbsent(rowKey, k -> new LinkedHashMap<>());
            rowFieldValues.computeIfAbsent(rowKey, k -> {
                Map<String, Object> vals = new LinkedHashMap<>();
                for (String rf : rowFields) {
                    vals.put(rf, row.get(rf));
                }
                return vals;
            });

            Map<String, Object> cellValues = new LinkedHashMap<>();
            for (String vf : valFields) {
                cellValues.put(vf, row.get(vf));
            }
            grouped.get(rowKey).put(colKey, cellValues);
        }

        // 4. Собираем итоговые строки
        List<Map<String, Object>> resultRows = new ArrayList<>();
        for (Map.Entry<String, Map<String, Map<String, Object>>> entry : grouped.entrySet()) {
            String rowKey = entry.getKey();
            Map<String, Map<String, Object>> colData = entry.getValue();

            Map<String, Object> resultRow = new LinkedHashMap<>();

            // Добавляем row fields
            Map<String, Object> rfVals = rowFieldValues.get(rowKey);
            resultRow.putAll(rfVals);

            // Добавляем pivot-ячейки
            for (String pivotKey : pivotColumnKeys) {
                Map<String, Object> cellValues = colData.get(pivotKey);
                for (String valField : valFields) {
                    String header = pivotKey + sep + valField;
                    resultRow.put(header, cellValues != null ? cellValues.get(valField) : null);
                }
            }

            resultRows.add(resultRow);
        }

        // 5. Формируем результат
        PivotResult result = new PivotResult();
        result.setRowHeaders(rowFields);
        result.setPivotColumnKeys(pivotColumnKeys);
        result.setValueFields(valFields);
        result.setAllColumnHeaders(allColumnHeaders);
        result.setRows(resultRows);

        return result;
    }

    /**
     * Автоматически определяет конфигурацию из SQL-метаданных.
     *
     * @param groupByFields все поля GROUP BY в порядке из запроса
     * @param allSelectFields все поля из SELECT
     * @param rowFieldCount сколько первых полей GROUP BY считать строками
     * @return PivotConfig
     */
    public PivotConfig autoConfig(List<String> groupByFields, List<String> allSelectFields, int rowFieldCount) {
        if (rowFieldCount < 1 || rowFieldCount >= groupByFields.size()) {
            throw new IllegalArgumentException(
                "rowFieldCount must be >= 1 and < groupByFields.size(). " +
                "Got " + rowFieldCount + " for " + groupByFields.size() + " group fields");
        }

        List<String> rowFields = groupByFields.subList(0, rowFieldCount);
        List<String> colFields = groupByFields.subList(rowFieldCount, groupByFields.size());

        Set<String> groupBySet = new HashSet<>(groupByFields);
        List<String> valueFields = allSelectFields.stream()
                .filter(f -> !groupBySet.contains(f))
                .collect(Collectors.toList());

        return new PivotConfig(rowFields, colFields, valueFields);
    }

    /**
     * Строит составной ключ из значений нескольких полей.
     */
    private String buildCompositeKey(Map<String, Object> row, List<String> fields, String separator) {
        return fields.stream()
                .map(f -> String.valueOf(row.getOrDefault(f, "NULL")))
                .collect(Collectors.joining(separator));
    }
}
```

### PivotService — Spring-сервис обёртка

```java
package com.example.pivot;

import org.springframework.stereotype.Service;

import java.util.List;
import java.util.Map;

@Service
public class PivotService {

    private final PivotConverter converter = new PivotConverter();

    /**
     * Полный pivot с явной конфигурацией.
     */
    public PivotResult pivot(List<Map<String, Object>> data, PivotConfig config) {
        return converter.convert(data, config);
    }

    /**
     * Pivot с автоматическим определением конфигурации.
     *
     * @param data результат запроса
     * @param groupByFields поля GROUP BY (в порядке из запроса)
     * @param allSelectFields все поля SELECT
     * @param rowFieldCount сколько первых GROUP BY полей = строки
     */
    public PivotResult pivot(List<Map<String, Object>> data,
                             List<String> groupByFields,
                             List<String> allSelectFields,
                             int rowFieldCount) {
        PivotConfig config = converter.autoConfig(groupByFields, allSelectFields, rowFieldCount);
        return converter.convert(data, config);
    }
}
```

## Тест

```java
package com.example.pivot;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;

import java.util.*;

import static org.junit.jupiter.api.Assertions.*;

class PivotConverterTest {

    @Test
    void testPivotByLegalEntityId_columnsGlobalId() throws Exception {
        // Исходные данные (упрощённо)
        List<Map<String, Object>> data = List.of(
            Map.of("legalEntityId", 4, "globalId", 6111,
                   "confirmedAt", 1, "closedAt", "2026-03-19T11:35:06",
                   "baseAmount", 57.75, "tradeDateTime", "2026-03-16T08:35:06.594+00:00",
                   "fxRate", 52.6418),
            Map.of("legalEntityId", 3, "globalId", 983422,
                   "confirmedAt", 1, "closedAt", "2026-03-18T11:35:04",
                   "baseAmount", 213.69, "tradeDateTime", "2026-03-17T15:35:04.594+00:00",
                   "fxRate", 55.8946),
            Map.of("legalEntityId", 1, "globalId", 929957,
                   "confirmedAt", 1, "closedAt", "2026-03-19T11:35:06",
                   "baseAmount", 38.45, "tradeDateTime", "2026-03-19T10:35:06.421+00:00",
                   "fxRate", 116.8395),
            Map.of("legalEntityId", 1, "globalId", 601106,
                   "confirmedAt", 1, "closedAt", "2026-03-13T11:35:07",
                   "baseAmount", 187.28, "tradeDateTime", "2026-03-13T19:35:07.594+00:00",
                   "fxRate", 97.4871),
            Map.of("legalEntityId", 3, "globalId", 848742,
                   "confirmedAt", 1, "closedAt", "2026-03-16T11:35:08",
                   "baseAmount", 124.05, "tradeDateTime", "2026-03-20T03:35:08.594+00:00",
                   "fxRate", 29.5618)
        );

        PivotConverter converter = new PivotConverter();

        // rowFields = [legalEntityId], columnFields = [globalId]
        // valueFields = [confirmedAt, closedAt, baseAmount, tradeDateTime, fxRate]
        PivotConfig config = converter.autoConfig(
            List.of("legalEntityId", "globalId"),
            List.of("legalEntityId", "globalId", "confirmedAt", "closedAt",
                     "baseAmount", "tradeDateTime", "fxRate"),
            1  // первое поле GROUP BY = строки
        );

        PivotResult result = converter.convert(data, config);

        // 3 уникальных legalEntityId: 4, 3, 1
        assertEquals(3, result.getRows().size());

        // 5 уникальных globalId → 5 pivot columns × 5 value fields = 25 data columns
        assertEquals(5, result.getPivotColumnKeys().size());
        assertEquals(25, result.getAllColumnHeaders().size());

        // Проверяем что legalEntityId=1 имеет два заполненных globalId
        Map<String, Object> row1 = result.getRows().stream()
                .filter(r -> Objects.equals(r.get("legalEntityId"), 1))
                .findFirst().orElseThrow();

        assertEquals(38.45, row1.get("929957 | baseAmount"));
        assertEquals(187.28, row1.get("601106 | baseAmount"));
        assertNull(row1.get("6111 | baseAmount")); // не принадлежит legalEntityId=1

        // Красивый вывод
        ObjectMapper mapper = new ObjectMapper();
        System.out.println("=== PIVOT RESULT ===");
        System.out.println("Row headers: " + result.getRowHeaders());
        System.out.println("Pivot columns: " + result.getPivotColumnKeys());
        System.out.println("Value fields: " + result.getValueFields());
        System.out.println("All column headers: " + result.getAllColumnHeaders());
        System.out.println("Data:");
        for (Map<String, Object> row : result.getRows()) {
            System.out.println(mapper.writerWithDefaultPrettyPrinter().writeValueAsString(row));
        }
    }
}
```

## Визуальное представление результата

Для вашего примера с `rowFieldCount=1` (строки = `legalEntityId`, колонки = `globalId`):

```
                 │  6111          │  983422        │  929957        │  601106        │  848742
                 │ conf│close│... │ conf│close│... │ conf│close│... │ conf│close│... │ conf│close│...
─────────────────┼──────────────────────────────────────────────────────────────────────────────────
legalEntityId=4  │  1  │03-19│... │ null│null │... │ null│null │... │ null│null │... │ null│null │...
legalEntityId=3  │ null│null │... │  1  │03-18│... │ null│null │... │ null│null │... │  1  │03-16│...
legalEntityId=1  │ null│null │... │ null│null │... │  1  │03-19│... │  1  │03-13│... │ null│null │...
```

## Ключевые моменты

1. **`autoConfig()`** — автоматически разделяет GROUP BY поля на row/column и определяет value-поля как всё что не в GROUP BY
2. **Составные ключи** — поддерживает несколько полей и для строк, и для колонок (через separator)
3. **Порядок сохраняется** — используется `LinkedHashMap`/`LinkedHashSet` для детерминированного порядка
4. **Null-safe** — если для данной строки нет значения по какой-то pivot-колонке, ставится `null`
5. **Гибкий separator** — можно менять разделитель в составных заголовках
