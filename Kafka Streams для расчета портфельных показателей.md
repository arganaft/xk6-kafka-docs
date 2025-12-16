Отличные идеи! Давайте разберём оба решения детально и сравним их.

## Решение 1: Агрегация в один JSON через Kafka

### Архитектура

```
┌────────────────────────────────────────────────────┐
│  Топик: market_data (raw ticks)                    │
│  20,000 инструментов × много тиков/сек             │
└───────────────┬────────────────────────────────────┘
                │
                ▼
┌────────────────────────────────────────────────────┐
│  Aggregator Service (1 инстанс)                    │
│  - Читает все тики                                 │
│  - Агрегирует за 1 секунду (avg, OHLC, volume)   │
│  - Упаковывает в 1 JSON со всеми 20K инструментами│
└───────────────┬────────────────────────────────────┘
                │
                ▼
┌────────────────────────────────────────────────────┐
│  Топик: aggregate_market_data                      │
│  1 сообщение/сек с данными по всем инструментам   │
│  Размер: ~20,000 инструментов × ~100 байт = 2 MB  │
└───────────────┬────────────────────────────────────┘
                │
                ▼
┌────────────────────────────────────────────────────┐
│  Analytics Service (3,000 реплик)                  │
│  Каждая реплика:                                   │
│  - Читает 1 сообщение/сек (2 MB)                  │
│  - Обрабатывает 100 портфелей                     │
└────────────────────────────────────────────────────┘
```

### Нагрузка

**Запись:**
- market_data: 20,000 записей/сек (или больше, если много тиков)
- aggregate_market_data: **1 запись/сек**

**Чтение:**
- Aggregator читает из market_data: 20,000 чтений/сек
- 3,000 реплик читают aggregate_market_data: **3,000 чтений/сек**

**Итого: 20,001 запись + 23,000 чтений = ~43,000 операций/сек** 

Это **1,400x лучше** чем наивный подход с GlobalKTable!

### Проблемы этого подхода

#### 1. **Single Point of Failure в Aggregator**

```java
// Aggregator Service - критичный компонент!
@Service
public class MarketDataAggregator {
    
    private final Map<String, List<Tick>> tickBuffer = new ConcurrentHashMap<>();
    
    @Scheduled(fixedRate = 1000) // Каждую секунду
    public void aggregateAndPublish() {
        Map<String, AggregatedData> aggregated = new HashMap<>();
        
        tickBuffer.forEach((ticker, ticks) -> {
            AggregatedData data = calculateOHLC(ticks); // Open, High, Low, Close
            aggregated.put(ticker, data);
        });
        
        // Упаковываем ВСЕ 20,000 инструментов в 1 JSON
        String json = objectMapper.writeValueAsString(aggregated);
        
        // Отправляем одно большое сообщение
        kafkaTemplate.send("aggregate_market_data", json);
        
        tickBuffer.clear();
    }
}
```

**Проблема:** Если Aggregator упадёт, вся система остановится. Нужно:
- Standby реплика с быстрым failover
- Health checks и автоматический перезапуск
- Distributed lock (Zookeeper/etcd) для активации standby

#### 2. **Большой размер сообщения**

```json
// Одно сообщение ~2 MB
{
  "timestamp": 1234567890,
  "data": {
    "AAPL": {"price": 150.25, "volume": 1000000, ...},
    "TSLA": {"price": 245.80, "volume": 500000, ...},
    // ... ещё 19,998 инструментов
  }
}
```

**Проблемы:**
- Kafka по умолчанию ограничивает размер сообщения (1 MB). Нужно увеличить `max.request.size`
- Каждая реплика десериализует 2 MB JSON, даже если ей нужны данные только по 20 инструментам из 20,000
- Network bandwidth: 3,000 реплик × 2 MB/сек = **6 GB/сек** трафика

#### 3. **Неэффективное использование данных**

```java
// Каждая реплика делает это
@KafkaListener(topics = "aggregate_market_data")
public void handleAggregatedData(String json) {
    Map<String, AggregatedData> allData = objectMapper.readValue(json, ...);
    // Получили 20,000 инструментов
    
    // Но используем только ~20 для наших 100 портфелей!
    Set<String> neededTickers = getTickersFromPortfolios(myPortfolios);
    // neededTickers.size() ≈ 20-50
    
    for (String ticker : neededTickers) {
        AggregatedData data = allData.get(ticker);
        updatePortfolios(ticker, data);
    }
    
    // Выбросили 99.9% данных!
}
```

#### 4. **Latency при десериализации**

Парсинг 2 MB JSON 3,000 раз в секунду = значительная CPU нагрузка.

### Оптимизация Решения 1

Можно улучшить:

```java
// Используем эффективный формат вместо JSON
// Protobuf, Avro, или MessagePack

// aggregated_market_data.proto
message AggregatedMarketData {
  int64 timestamp = 1;
  map<string, InstrumentData> data = 2;
}

message InstrumentData {
  double price = 1;
  int64 volume = 2;
  double high = 3;
  double low = 4;
}

// Размер уменьшается с 2 MB до ~400 KB
// Десериализация в 5-10 раз быстрее
```

---

## Решение 2: Redis Pub/Sub

Это **намного интереснее**! Давайте разберём два варианта.

### Вариант 2A: Агрегация в Redis

```
┌────────────────────────────────────────────────────┐
│  Топик: market_data                                │
└───────────────┬────────────────────────────────────┘
                │
                ▼
┌────────────────────────────────────────────────────┐
│  Market Data Ingestion Service                     │
│  - Читает тики из Kafka                           │
│  - Агрегирует за 1 сек                            │
│  - Пишет в Redis (TTL: 5 сек)                     │
└───────────────┬────────────────────────────────────┘
                │
                ▼
┌────────────────────────────────────────────────────┐
│  Redis                                             │
│  Key: "market:{ticker}"                            │
│  Value: {price, volume, timestamp}                 │
│  + Pub/Sub: channel "market_updates"              │
└───────────────┬────────────────────────────────────┘
                │ Pub/Sub
                ▼
┌────────────────────────────────────────────────────┐
│  Analytics Service (3,000 реплик)                  │
│  Subscribe: "market_updates"                       │
└────────────────────────────────────────────────────┘
```

```java
// Market Data Ingestion Service
@Service
public class RedisMarketDataPublisher {
    
    @Autowired
    private RedisTemplate<String, MarketData> redisTemplate;
    
    private final Map<String, List<Tick>> tickBuffer = new ConcurrentHashMap<>();
    
    @KafkaListener(topics = "market_data")
    public void handleTick(String ticker, Tick tick) {
        tickBuffer.computeIfAbsent(ticker, k -> new ArrayList<>()).add(tick);
    }
    
    @Scheduled(fixedRate = 1000)
    public void publishAggregated() {
        tickBuffer.forEach((ticker, ticks) -> {
            MarketData aggregated = calculateOHLC(ticks);
            
            // Пишем в Redis с TTL
            redisTemplate.opsForValue().set(
                "market:" + ticker, 
                aggregated, 
                5, TimeUnit.SECONDS
            );
            
            // Публикуем событие
            redisTemplate.convertAndSend("market_updates", 
                new MarketUpdate(ticker, aggregated)
            );
        });
        
        tickBuffer.clear();
    }
}

// Analytics Service
@Service
public class RedisAnalyticsService {
    
    @RedisMessageListener(channels = "market_updates")
    public void handleMarketUpdate(MarketUpdate update) {
        // Получаем обновление по одному тикеру
        // Обрабатываем только портфели, содержащие этот тикер
        
        Set<String> affectedUsers = tickerToUsersIndex.get(update.ticker);
        if (affectedUsers != null) {
            for (String userId : affectedUsers) {
                updatePortfolio(userId, update.ticker, update.data);
            }
        }
    }
}
```

**Проблема Redis Pub/Sub:**

Redis Pub/Sub **не гарантирует доставку**! Если реплика отключилась на 2 секунды:
- Она пропустит все обновления за это время
- Портфели будут рассчитаны на устаревших данных
- Нет механизма восстановления

### Вариант 2B: Умная подписка (ВАШ ЛУЧШИЙ ВАРИАНТ!)

Это самое элегантное решение! Давайте реализуем полностью.

```
┌────────────────────────────────────────────────────┐
│  Топик: market_data                                │
└───────────────┬────────────────────────────────────┘
                │
                ▼
┌────────────────────────────────────────────────────┐
│  Market Data Ingestion Service                     │
│  - Читает тики из Kafka                           │
│  - Пишет последнее значение в Redis               │
│  - Redis Streams для надёжности                   │
└───────────────┬────────────────────────────────────┘
                │
                ▼
┌────────────────────────────────────────────────────┐
│  Redis                                             │
│  1. Hash: "market:{ticker}" → latest data          │
│  2. Stream per ticker: "stream:{ticker}"           │
│  3. Hash: "subscriptions:{replicaId}" → [tickers]  │
└───────────────┬────────────────────────────────────┘
                │
                ▼
┌────────────────────────────────────────────────────┐
│  Subscription Manager Service                      │
│  - Знает, какая реплика подписана на какие тикеры│
│  - Маршрутизирует обновления                      │
└───────────────┬────────────────────────────────────┘
                │
                ▼
┌────────────────────────────────────────────────────┐
│  Analytics Service (3,000 реплик)                  │
│  - Регистрирует свои подписки в Redis             │
│  - Получает только нужные тикеры                  │
└────────────────────────────────────────────────────┘
```

### Полная реализация Решения 2B

```java
// ============================================
// 1. Market Data Ingestion Service
// ============================================

@Service
public class MarketDataIngestionService {
    
    @Autowired
    private StringRedisTemplate redisTemplate;
    
    private final Map<String, TickAggregator> aggregators = new ConcurrentHashMap<>();
    
    @KafkaListener(topics = "market_data", concurrency = "10")
    public void handleTick(String ticker, Tick tick) {
        aggregators.computeIfAbsent(ticker, TickAggregator::new).addTick(tick);
    }
    
    @Scheduled(fixedRate = 1000) // Каждую секунду
    public void flushAggregatedData() {
        aggregators.forEach((ticker, aggregator) -> {
            MarketData data = aggregator.aggregate();
            
            // 1. Сохраняем последнее значение (для новых подписчиков)
            redisTemplate.opsForHash().put(
                "market:latest", 
                ticker, 
                serializeMarketData(data)
            );
            
            // 2. Добавляем в Stream для надёжной доставки
            redisTemplate.opsForStream().add(
                StreamRecords.newRecord()
                    .ofObject(data)
                    .withStreamKey("stream:" + ticker)
            );
            
            aggregator.reset();
        });
    }
}

// ============================================
// 2. Analytics Service (реплика)
// ============================================

@Service
public class AnalyticsService {
    
    @Autowired
    private StringRedisTemplate redisTemplate;
    
    @Value("${replica.id}") // Уникальный ID реплики из Kubernetes
    private String replicaId;
    
    // Портфели, за которые отвечает эта реплика
    private final Map<String, Portfolio> portfolios = new ConcurrentHashMap<>();
    
    // Индекс: ticker → Set<userId>
    private final Map<String, Set<String>> tickerToUsers = new ConcurrentHashMap<>();
    
    @PostConstruct
    public void initialize() {
        // 1. Загружаем портфели из БД (по partition key)
        loadPortfoliosForThisReplica();
        
        // 2. Строим индекс подписок
        buildTickerIndex();
        
        // 3. Регистрируем подписки в Redis
        registerSubscriptions();
        
        // 4. Запускаем consumer для наших тикеров
        startStreamConsumers();
    }
    
    private void buildTickerIndex() {
        portfolios.values().forEach(portfolio -> {
            portfolio.getPositions().forEach(position -> {
                tickerToUsers
                    .computeIfAbsent(position.getTicker(), k -> ConcurrentHashMap.newKeySet())
                    .add(portfolio.getUserId());
            });
        });
        
        log.info("Replica {} subscribed to {} tickers for {} users", 
            replicaId, tickerToUsers.size(), portfolios.size());
    }
    
    private void registerSubscriptions() {
        // Сохраняем в Redis, какие тикеры нужны этой реплике
        Set<String> tickers = tickerToUsers.keySet();
        
        redisTemplate.opsForHash().put(
            "subscriptions:replicas",
            replicaId,
            String.join(",", tickers)
        );
        
        // Также создаём consumer group для каждого тикера
        tickers.forEach(ticker -> {
            try {
                redisTemplate.opsForStream().createGroup(
                    "stream:" + ticker, 
                    ReadOffset.latest(), 
                    "analytics-" + replicaId
                );
            } catch (Exception e) {
                // Group уже существует
            }
        });
    }
    
    private void startStreamConsumers() {
        // Запускаем по одному consumer на ticker (можно оптимизировать)
        tickerToUsers.keySet().forEach(ticker -> {
            // Используем Spring Data Redis Streams
            StreamMessageListenerContainer<String, MapRecord<String, String, String>> container = 
                createListenerContainer();
            
            container.receive(
                Consumer.from("analytics-" + replicaId, replicaId),
                StreamOffset.create("stream:" + ticker, ReadOffset.lastConsumed()),
                message -> handleMarketDataUpdate(ticker, message)
            );
            
            container.start();
        });
    }
    
    private void handleMarketDataUpdate(String ticker, MapRecord<String, String, String> message) {
        MarketData data = deserializeMarketData(message.getValue());
        
        // Обновляем только портфели, содержащие этот ticker
        Set<String> affectedUsers = tickerToUsers.get(ticker);
        if (affectedUsers != null) {
            affectedUsers.forEach(userId -> {
                Portfolio portfolio = portfolios.get(userId);
                if (portfolio != null) {
                    updatePortfolioMetrics(portfolio, ticker, data);
                }
            });
        }
        
        // Подтверждаем обработку
        redisTemplate.opsForStream().acknowledge(
            "analytics-" + replicaId,
            message
        );
    }
    
    private void updatePortfolioMetrics(Portfolio portfolio, String ticker, MarketData data) {
        Position position = portfolio.getPosition(ticker);
        if (position == null) return;
        
        // Рассчитываем метрики
        double currentValue = position.getQuantity() * data.getPrice();
        double costBasis = position.getQuantity() * position.getAvgPrice();
        double pnl = currentValue - costBasis;
        double pnlPercent = (pnl / costBasis) * 100;
        
        // Обновляем позицию
        position.setCurrentValue(currentValue);
        position.setPnl(pnl);
        position.setPnlPercent(pnlPercent);
        
        // Пересчитываем общие метрики портфеля
        portfolio.recalculateMetrics();
        
        // Сохраняем в Redis для быстрого доступа
        redisTemplate.opsForHash().put(
            "portfolio:" + portfolio.getUserId(),
            "metrics",
            serializeMetrics(portfolio.getMetrics())
        );
        
        // Опционально: публикуем обновление для UI
        if (shouldNotifyUser(portfolio)) {
            publishPortfolioUpdate(portfolio);
        }
    }
    
    // Обработка изменений портфеля
    @KafkaListener(topics = "portfolio-events")
    public void handlePortfolioEvent(String userId, PortfolioEvent event) {
        switch (event.getType()) {
            case POSITION_ADDED:
                handlePositionAdded(userId, event.getPosition());
                break;
            case POSITION_REMOVED:
                handlePositionRemoved(userId, event.getTicker());
                break;
            case POSITION_UPDATED:
                handlePositionUpdated(userId, event.getPosition());
                break;
        }
    }
    
    private void handlePositionAdded(String userId, Position position) {
        Portfolio portfolio = portfolios.get(userId);
        if (portfolio != null) {
            portfolio.addPosition(position);
            
            // Обновляем индекс
            tickerToUsers
                .computeIfAbsent(position.getTicker(), k -> ConcurrentHashMap.newKeySet())
                .add(userId);
            
            // Если это новый ticker для реплики, подписываемся
            if (tickerToUsers.get(position.getTicker()).size() == 1) {
                subscribeToNewTicker(position.getTicker());
            }
            
            // Получаем текущую цену и обновляем метрики
            MarketData currentData = getCurrentMarketData(position.getTicker());
            if (currentData != null) {
                updatePortfolioMetrics(portfolio, position.getTicker(), currentData);
            }
        }
    }
    
    private void handlePositionRemoved(String userId, String ticker) {
        Portfolio portfolio = portfolios.get(userId);
        if (portfolio != null) {
            portfolio.removePosition(ticker);
            
            // Обновляем индекс
            Set<String> users = tickerToUsers.get(ticker);
            if (users != null) {
                users.remove(userId);
                
                // Если больше никто не держит этот ticker, отписываемся
                if (users.isEmpty()) {
                    unsubscribeFromTicker(ticker);
                    tickerToUsers.remove(ticker);
                }
            }
        }
    }
    
    private MarketData getCurrentMarketData(String ticker) {
        String data = (String) redisTemplate.opsForHash().get("market:latest", ticker);
        return data != null ? deserializeMarketData(data) : null;
    }
    
    private void subscribeToNewTicker(String ticker) {
        // Создаём consumer для нового ticker
        try {
            redisTemplate.opsForStream().createGroup(
                "stream:" + ticker,
                ReadOffset.latest(),
                "analytics-" + replicaId
            );
            
            // Запускаем listener
            // (код аналогичен startStreamConsumers)
            
            // Обновляем подписки в Redis
            updateSubscriptionsInRedis();
            
            log.info("Replica {} subscribed to new ticker: {}", replicaId, ticker);
        } catch (Exception e) {
            log.error("Failed to subscribe to ticker: {}", ticker, e);
        }
    }
    
    private void unsubscribeFromTicker(String ticker) {
        // Останавливаем consumer
        // Удаляем consumer group
        try {
            redisTemplate.opsForStream().destroyGroup("stream:" + ticker, "analytics-" + replicaId);
            updateSubscriptionsInRedis();
            log.info("Replica {} unsubscribed from ticker: {}", replicaId, ticker);
        } catch (Exception e) {
            log.error("Failed to unsubscribe from ticker: {}", ticker, e);
        }
    }
}

// ============================================
// 3. Subscription Manager (опционально)
// ============================================

@Service
public class SubscriptionManagerService {
    
    /**
     * Этот сервис может оптимизировать распределение подписок
     * Например, если ticker очень популярен (в 50% портфелей),
     * можно использовать broadcast вместо индивидуальной доставки
     */
    
    @Scheduled(fixedRate = 60000) // Каждую минуту
    public void analyzeSubscriptions() {
        // Анализируем популярность тикеров
        Map<String, Integer> tickerPopularity = calculateTickerPopularity();
        
        // Если ticker в >70% реплик, переключаем на broadcast
        tickerPopularity.forEach((ticker, replicaCount) -> {
            if (replicaCount > totalReplicas * 0.7) {
                switchToBroadcast(ticker);
            }
        });
    }
}
```

### Конфигурация Redis

```yaml
# redis.conf
maxmemory 32gb
maxmemory-policy allkeys-lru  # Автоматически удаляем старые данные

# Для Streams
stream-node-max-bytes 4096
stream-node-max-entries 100

# Persistence (опционально)
save 60 10000  # Сохраняем каждую минуту если >=10k изменений
appendonly yes  # AOF для надёжности
```

```java
// Spring Boot application.yml
spring:
  redis:
    host: redis-cluster
    port: 6379
    timeout: 2000ms
    lettuce:
      pool:
        max-active: 50  # По числу тикеров на реплику
        max-idle: 20
        min-idle: 5
```

---

## Сравнение всех решений

| Критерий | Решение 1 (Kafka Agg) | Решение 2A (Redis Pub/Sub) | **Решение 2B (Redis Streams)** |
|----------|----------------------|---------------------------|-------------------------------|
| **Записей в Kafka/сек** | 1 | 0 | 0 |
| **Чтений из Kafka/сек** | 3,000 | 0 | 0 |
| **Записей в Redis/сек** | 0 | 20,000 | 20,000 |
| **Чтений из Redis/сек** | 0 | 3,000 broadcasts | ~100,000 (только нужные) |
| **Network traffic** | 6 GB/сек | 60 MB/сек | **~10 MB/сек** |
| **Гарантии доставки** | ✅ Да | ❌ Нет | ✅ Да (at-least-once) |
| **Latency** | 1-2 сек | <100ms | **<50ms** |
| **Single point of failure** | ⚠️ Aggregator | ⚠️ Ingestion | ⚠️ Ingestion |
| **Масштабируемость** | Средняя | Низкая | **Отличная** |
| **Сложность** | Низкая | Средняя | Высокая |
| **Эффективность** | Низкая (99% данных не используется) | Средняя | **Высокая** |

## Итоговая рекомендация

**Используйте гибридный подход:**

### Фаза 1 (200 инструментов, 15K пользователей):
- **Решение 1** (Kafka агрегация) — простое и достаточное

### Фаза 2 (20K инструментов, 300K пользователей):
- **Решение 2B** (Redis Streams с умными подписками) — оптимальное

### Расчёт для Решения 2B

**Предположения:**
- Средний портфель: 20 инструментов
- 300,000 пользователей / 100 портфелей на реплику = 3,000 реплик
- Каждая реплика подписана на ~2,000 уникальных тикеров (с учётом пересечений)

**Network traffic:**
- Каждое обновление тикера: ~100 байт
- 20,000 тикеров × 1 обновление/сек = 20,000 обновлений/сек
- В среднем каждый тикер нужен 45 репликам (300K пользователей / 20K тикеров × 20 инструментов / 100 портфелей)
- **20,000 × 45 × 100 байт = 90 MB/сек** общий трафик
- На одну реплику: 90 MB / 3,000 = **30 KB/сек** — ничтожно!

**Сравните с Решением 1:**
- 3,000 реплик × 2 MB/сек = 6,000 MB/сек = **6 GB/сек**

**Выигрыш: 66x меньше трафика!**

### Финальная архитектура

```
                    ┌──────────────┐
                    │   Kafka      │
                    │  market_data │ (сырые тики)
                    └───────┬──────┘
                            │
                            ▼
                ┌────────────────────────┐
                │  Ingestion Service     │
                │  (5 реплик для HA)     │
                │  - Aggregates ticks    │
                │  - Writes to Redis     │
                └────────────┬───────────┘
                             │
                             ▼
                ┌────────────────────────┐
                │   Redis Cluster        │
                │   (3 masters, 3 slaves)│
                │   - Streams per ticker │
                │   - Latest values      │
                └────────────┬───────────┘
                             │
              ┌──────────────┴──────────────┐
              │                             │
              ▼                             ▼
    ┌──────────────────┐        ┌──────────────────┐
    │ Analytics Svc    │  ...   │ Analytics Svc    │
    │ Replica 1        │        │ Replica 3000     │
    │ - 100 portfolios │        │ - 100 portfolios │
    │ - ~2K tickers    │        │ - ~2K tickers    │
    └──────────────────┘        └──────────────────┘
```

Отлично! Давайте построим полноценную систему мониторинга и обработки ошибок для нашей архитектуры.

## Архитектура мониторинга

```
┌────────────────────────────────────────────────────────────┐
│                     Observability Stack                    │
├────────────────────────────────────────────────────────────┤
│  Metrics: Prometheus + Grafana                             │
│  Logs: ELK Stack (Elasticsearch + Logstash + Kibana)      │
│  Traces: Jaeger / Tempo                                    │
│  Alerts: AlertManager + PagerDuty                          │
└────────────────────────────────────────────────────────────┘
```

## 1. Метрики (Metrics)

### 1.1 Ключевые метрики системы

```java
// ============================================
// Metrics Configuration
// ============================================

@Configuration
public class MetricsConfig {
    
    @Bean
    public MeterRegistry meterRegistry() {
        return new PrometheusMeterRegistry(PrometheusConfig.DEFAULT);
    }
}

// ============================================
// Market Data Ingestion Service Metrics
// ============================================

@Service
public class MonitoredMarketDataIngestionService {
    
    @Autowired
    private MeterRegistry registry;
    
    // Счётчики
    private Counter ticksReceived;
    private Counter ticksProcessed;
    private Counter ticksFailed;
    private Counter redisWriteErrors;
    
    // Таймеры
    private Timer aggregationTimer;
    private Timer redisWriteTimer;
    
    // Gauges
    private AtomicInteger bufferSize;
    private AtomicInteger activeAggregators;
    
    @PostConstruct
    public void initMetrics() {
        // Счётчики обработки
        ticksReceived = Counter.builder("market_data.ticks.received")
            .description("Total number of ticks received from Kafka")
            .tag("service", "ingestion")
            .register(registry);
        
        ticksProcessed = Counter.builder("market_data.ticks.processed")
            .description("Total number of ticks successfully processed")
            .tag("service", "ingestion")
            .register(registry);
        
        ticksFailed = Counter.builder("market_data.ticks.failed")
            .description("Total number of ticks that failed processing")
            .tag("service", "ingestion")
            .register(registry);
        
        redisWriteErrors = Counter.builder("redis.write.errors")
            .description("Total number of Redis write failures")
            .tag("service", "ingestion")
            .register(registry);
        
        // Таймеры для измерения latency
        aggregationTimer = Timer.builder("market_data.aggregation.duration")
            .description("Time taken to aggregate ticks")
            .publishPercentiles(0.5, 0.95, 0.99)
            .register(registry);
        
        redisWriteTimer = Timer.builder("redis.write.duration")
            .description("Time taken to write to Redis")
            .publishPercentiles(0.5, 0.95, 0.99)
            .register(registry);
        
        // Gauges для текущего состояния
        Gauge.builder("market_data.buffer.size", bufferSize, AtomicInteger::get)
            .description("Current number of ticks in buffer")
            .register(registry);
        
        Gauge.builder("market_data.aggregators.active", activeAggregators, AtomicInteger::get)
            .description("Number of active aggregators")
            .register(registry);
        
        // Кастомная метрика: скорость обработки
        Gauge.builder("market_data.processing.rate", this, service -> 
            ticksProcessed.count() / 
            Duration.between(startTime, Instant.now()).getSeconds()
        )
            .description("Ticks processed per second")
            .register(registry);
    }
    
    @KafkaListener(topics = "market_data", concurrency = "10")
    public void handleTick(String ticker, Tick tick) {
        ticksReceived.increment();
        bufferSize.incrementAndGet();
        
        try {
            aggregators.computeIfAbsent(ticker, k -> {
                activeAggregators.incrementAndGet();
                return new TickAggregator(k);
            }).addTick(tick);
            
            ticksProcessed.increment();
        } catch (Exception e) {
            ticksFailed.increment();
            log.error("Failed to process tick for {}", ticker, e);
        } finally {
            bufferSize.decrementAndGet();
        }
    }
    
    @Scheduled(fixedRate = 1000)
    public void flushAggregatedData() {
        aggregationTimer.record(() -> {
            aggregators.forEach((ticker, aggregator) -> {
                try {
                    MarketData data = aggregator.aggregate();
                    
                    redisWriteTimer.record(() -> {
                        writeToRedis(ticker, data);
                    });
                    
                    aggregator.reset();
                    
                } catch (Exception e) {
                    redisWriteErrors.increment();
                    log.error("Failed to write to Redis for ticker: {}", ticker, e);
                    
                    // Добавляем в dead letter queue
                    handleFailedWrite(ticker, data, e);
                }
            });
        });
    }
    
    // Метрика для Redis connection pool
    @Scheduled(fixedRate = 10000)
    public void recordRedisPoolMetrics() {
        GenericObjectPoolConfig poolConfig = redisConnectionFactory.getPoolConfig();
        
        Gauge.builder("redis.pool.active", poolConfig, GenericObjectPoolConfig::getMaxTotal)
            .register(registry);
        
        Gauge.builder("redis.pool.idle", poolConfig, GenericObjectPoolConfig::getMaxIdle)
            .register(registry);
    }
}

// ============================================
// Analytics Service Metrics
// ============================================

@Service
public class MonitoredAnalyticsService {
    
    @Autowired
    private MeterRegistry registry;
    
    // Метрики обработки портфелей
    private Counter portfoliosUpdated;
    private Counter portfolioUpdatesFailed;
    private Timer portfolioUpdateTimer;
    
    // Метрики подписок
    private AtomicInteger activeSubscriptions;
    private Counter subscriptionErrors;
    
    // Метрики качества данных
    private Counter staleDataDetected;
    private Counter missingMarketData;
    
    // Бизнес-метрики
    private DistributionSummary portfolioValueDistribution;
    private DistributionSummary pnlDistribution;
    
    @PostConstruct
    public void initMetrics() {
        portfoliosUpdated = Counter.builder("portfolio.updates.total")
            .description("Total number of portfolio updates")
            .tag("replica", replicaId)
            .register(registry);
        
        portfolioUpdatesFailed = Counter.builder("portfolio.updates.failed")
            .description("Failed portfolio updates")
            .tag("replica", replicaId)
            .register(registry);
        
        portfolioUpdateTimer = Timer.builder("portfolio.update.duration")
            .description("Time to update a portfolio")
            .publishPercentiles(0.5, 0.95, 0.99, 0.999)
            .register(registry);
        
        activeSubscriptions = registry.gauge(
            "redis.subscriptions.active",
            Tags.of("replica", replicaId),
            new AtomicInteger(0)
        );
        
        subscriptionErrors = Counter.builder("redis.subscription.errors")
            .tag("replica", replicaId)
            .register(registry);
        
        staleDataDetected = Counter.builder("market_data.stale.detected")
            .description("Number of times stale data was detected")
            .tag("replica", replicaId)
            .register(registry);
        
        missingMarketData = Counter.builder("market_data.missing")
            .description("Number of times market data was missing for a ticker")
            .tag("replica", replicaId)
            .register(registry);
        
        // Бизнес-метрики
        portfolioValueDistribution = DistributionSummary.builder("portfolio.value")
            .description("Distribution of portfolio values")
            .baseUnit("USD")
            .scale(1.0)
            .register(registry);
        
        pnlDistribution = DistributionSummary.builder("portfolio.pnl")
            .description("Distribution of P&L")
            .baseUnit("USD")
            .register(registry);
        
        // Метрики по тикерам
        Gauge.builder("portfolio.tickers.unique", tickerToUsers, Map::size)
            .description("Number of unique tickers tracked by this replica")
            .tag("replica", replicaId)
            .register(registry);
        
        Gauge.builder("portfolio.users.count", portfolios, Map::size)
            .description("Number of users managed by this replica")
            .tag("replica", replicaId)
            .register(registry);
    }
    
    private void handleMarketDataUpdate(String ticker, MapRecord<String, String, String> message) {
        portfolioUpdateTimer.record(() -> {
            try {
                MarketData data = deserializeMarketData(message.getValue());
                
                // Проверка на устаревшие данные
                if (isStale(data)) {
                    staleDataDetected.increment();
                    log.warn("Stale market data detected for ticker: {}, age: {} ms", 
                        ticker, System.currentTimeMillis() - data.getTimestamp());
                }
                
                Set<String> affectedUsers = tickerToUsers.get(ticker);
                if (affectedUsers != null) {
                    affectedUsers.forEach(userId -> {
                        try {
                            Portfolio portfolio = portfolios.get(userId);
                            if (portfolio != null) {
                                updatePortfolioMetrics(portfolio, ticker, data);
                                portfoliosUpdated.increment();
                                
                                // Записываем бизнес-метрики
                                portfolioValueDistribution.record(portfolio.getTotalValue());
                                pnlDistribution.record(portfolio.getTotalPnL());
                            }
                        } catch (Exception e) {
                            portfolioUpdatesFailed.increment();
                            log.error("Failed to update portfolio for user: {}", userId, e);
                        }
                    });
                } else {
                    log.warn("No users subscribed to ticker: {}", ticker);
                }
                
                // Подтверждаем обработку
                redisTemplate.opsForStream().acknowledge(
                    "analytics-" + replicaId,
                    message
                );
                
            } catch (Exception e) {
                portfolioUpdatesFailed.increment();
                log.error("Failed to handle market data update for ticker: {}", ticker, e);
                
                // Повторная обработка через backoff
                scheduleRetry(ticker, message);
            }
        });
    }
    
    // Метрики Redis Streams
    @Scheduled(fixedRate = 5000)
    public void recordRedisStreamMetrics() {
        tickerToUsers.keySet().forEach(ticker -> {
            try {
                StreamInfo.XInfoStream info = redisTemplate.opsForStream()
                    .info("stream:" + ticker);
                
                registry.gauge(
                    "redis.stream.length",
                    Tags.of("ticker", ticker, "replica", replicaId),
                    info.getLength()
                );
                
                // Lag метрика
                StreamInfo.XInfoConsumers consumers = redisTemplate.opsForStream()
                    .consumers("stream:" + ticker, "analytics-" + replicaId);
                
                consumers.forEach(consumer -> {
                    registry.gauge(
                        "redis.stream.lag",
                        Tags.of("ticker", ticker, "consumer", consumer.getName()),
                        consumer.getPending()
                    );
                });
                
            } catch (Exception e) {
                log.debug("Failed to get stream info for ticker: {}", ticker);
            }
        });
    }
    
    // Health check метрики
    @Scheduled(fixedRate = 1000)
    public void recordHealthMetrics() {
        // CPU
        OperatingSystemMXBean osBean = ManagementFactory.getOperatingSystemMXBean();
        registry.gauge("system.cpu.usage", osBean.getSystemLoadAverage());
        
        // Memory
        MemoryMXBean memoryBean = ManagementFactory.getMemoryMXBean();
        MemoryUsage heapUsage = memoryBean.getHeapMemoryUsage();
        
        registry.gauge("jvm.memory.used", heapUsage.getUsed());
        registry.gauge("jvm.memory.max", heapUsage.getMax());
        registry.gauge("jvm.memory.usage.percent", 
            (double) heapUsage.getUsed() / heapUsage.getMax() * 100);
        
        // GC
        ManagementFactory.getGarbageCollectorMXBeans().forEach(gc -> {
            registry.gauge("jvm.gc.count", Tags.of("gc", gc.getName()), gc.getCollectionCount());
            registry.gauge("jvm.gc.time", Tags.of("gc", gc.getName()), gc.getCollectionTime());
        });
    }
}

// ============================================
// Custom Health Indicators
// ============================================

@Component
public class RedisHealthIndicator implements HealthIndicator {
    
    @Autowired
    private StringRedisTemplate redisTemplate;
    
    @Override
    public Health health() {
        try {
            String pong = redisTemplate.getConnectionFactory()
                .getConnection()
                .ping();
            
            if ("PONG".equals(pong)) {
                return Health.up()
                    .withDetail("redis", "Available")
                    .build();
            }
            
            return Health.down()
                .withDetail("redis", "No response")
                .build();
                
        } catch (Exception e) {
            return Health.down()
                .withException(e)
                .build();
        }
    }
}

@Component
public class KafkaHealthIndicator implements HealthIndicator {
    
    @Autowired
    private KafkaTemplate<String, Object> kafkaTemplate;
    
    @Override
    public Health health() {
        try {
            ListenableFuture<SendResult<String, Object>> future = 
                kafkaTemplate.send("health-check", "ping");
            
            future.get(5, TimeUnit.SECONDS);
            
            return Health.up()
                .withDetail("kafka", "Available")
                .build();
                
        } catch (Exception e) {
            return Health.down()
                .withDetail("kafka", "Unavailable")
                .withException(e)
                .build();
        }
    }
}

@Component
public class DataFreshnessHealthIndicator implements HealthIndicator {
    
    @Autowired
    private StringRedisTemplate redisTemplate;
    
    private static final long MAX_STALENESS_MS = 5000; // 5 секунд
    
    @Override
    public Health health() {
        try {
            // Проверяем свежесть данных для популярных тикеров
            List<String> popularTickers = Arrays.asList("AAPL", "TSLA", "MSFT");
            
            long now = System.currentTimeMillis();
            List<String> staleTickers = new ArrayList<>();
            
            for (String ticker : popularTickers) {
                String data = (String) redisTemplate.opsForHash()
                    .get("market:latest", ticker);
                
                if (data != null) {
                    MarketData marketData = deserializeMarketData(data);
                    long age = now - marketData.getTimestamp();
                    
                    if (age > MAX_STALENESS_MS) {
                        staleTickers.add(ticker + " (" + age + "ms)");
                    }
                }
            }
            
            if (staleTickers.isEmpty()) {
                return Health.up()
                    .withDetail("data_freshness", "OK")
                    .build();
            }
            
            return Health.down()
                .withDetail("stale_tickers", staleTickers)
                .build();
                
        } catch (Exception e) {
            return Health.down()
                .withException(e)
                .build();
        }
    }
}
```

## 2. Grafana Dashboard

```json
{
  "dashboard": {
    "title": "Portfolio Analytics Platform",
    "panels": [
      {
        "title": "Market Data Ingestion Rate",
        "targets": [
          {
            "expr": "rate(market_data_ticks_received_total[1m])",
            "legendFormat": "Received"
          },
          {
            "expr": "rate(market_data_ticks_processed_total[1m])",
            "legendFormat": "Processed"
          },
          {
            "expr": "rate(market_data_ticks_failed_total[1m])",
            "legendFormat": "Failed"
          }
        ]
      },
      {
        "title": "Processing Latency (p95, p99)",
        "targets": [
          {
            "expr": "histogram_quantile(0.95, rate(portfolio_update_duration_bucket[5m]))",
            "legendFormat": "p95"
          },
          {
            "expr": "histogram_quantile(0.99, rate(portfolio_update_duration_bucket[5m]))",
            "legendFormat": "p99"
          }
        ]
      },
      {
        "title": "Redis Stream Lag",
        "targets": [
          {
            "expr": "max(redis_stream_lag) by (ticker)",
            "legendFormat": "{{ticker}}"
          }
        ],
        "alert": {
          "conditions": [
            {
              "evaluator": {
                "params": [1000],
                "type": "gt"
              },
              "operator": {
                "type": "and"
              },
              "query": {
                "params": ["A", "5m", "now"]
              },
              "reducer": {
                "type": "avg"
              },
              "type": "query"
            }
          ]
        }
      },
      {
        "title": "Portfolio Updates per Second",
        "targets": [
          {
            "expr": "sum(rate(portfolio_updates_total[1m])) by (replica)",
            "legendFormat": "Replica {{replica}}"
          }
        ]
      },
      {
        "title": "Error Rate",
        "targets": [
          {
            "expr": "sum(rate(portfolio_updates_failed_total[1m])) / sum(rate(portfolio_updates_total[1m])) * 100",
            "legendFormat": "Error Rate %"
          }
        ],
        "alert": {
          "conditions": [
            {
              "evaluator": {
                "params": [5],
                "type": "gt"
              }
            }
          ],
          "message": "Portfolio update error rate exceeded 5%"
        }
      },
      {
        "title": "Active Subscriptions by Replica",
        "targets": [
          {
            "expr": "redis_subscriptions_active",
            "legendFormat": "Replica {{replica}}"
          }
        ]
      },
      {
        "title": "Memory Usage",
        "targets": [
          {
            "expr": "jvm_memory_usage_percent",
            "legendFormat": "{{instance}}"
          }
        ]
      },
      {
        "title": "Portfolio Value Distribution",
        "targets": [
          {
            "expr": "histogram_quantile(0.5, sum(rate(portfolio_value_bucket[5m])) by (le))",
            "legendFormat": "Median"
          },
          {
            "expr": "histogram_quantile(0.95, sum(rate(portfolio_value_bucket[5m])) by (le))",
            "legendFormat": "p95"
          }
        ]
      },
      {
        "title": "Data Freshness",
        "targets": [
          {
            "expr": "time() - market_data_latest_timestamp",
            "legendFormat": "Age (seconds)"
          }
        ]
      }
    ]
  }
}
```

## 3. Обработка ошибок

### 3.1 Стратегии retry

```java
// ============================================
// Retry Configuration
// ============================================

@Configuration
public class RetryConfig {
    
    @Bean
    public RetryTemplate retryTemplate() {
        RetryTemplate template = new RetryTemplate();
        
        // Exponential backoff: 100ms, 200ms, 400ms, 800ms, 1600ms
        ExponentialBackOffPolicy backOffPolicy = new ExponentialBackOffPolicy();
        backOffPolicy.setInitialInterval(100);
        backOffPolicy.setMultiplier(2.0);
        backOffPolicy.setMaxInterval(10000);
        
        template.setBackOffPolicy(backOffPolicy);
        
        // Retry до 5 раз
        SimpleRetryPolicy retryPolicy = new SimpleRetryPolicy();
        retryPolicy.setMaxAttempts(5);
        
        template.setRetryPolicy(retryPolicy);
        
        // Логирование retry
        template.registerListener(new RetryListenerSupport() {
            @Override
            public <T, E extends Throwable> void onError(
                RetryContext context,
                RetryCallback<T, E> callback,
                Throwable throwable
            ) {
                log.warn("Retry attempt {} failed: {}",
                    context.getRetryCount(),
                    throwable.getMessage()
                );
            }
        });
        
        return template;
    }
}

// ============================================
// Circuit Breaker для Redis
// ============================================

@Service
public class ResilientRedisService {
    
    @Autowired
    private StringRedisTemplate redisTemplate;
    
    @Autowired
    private RetryTemplate retryTemplate;
    
    private final CircuitBreaker circuitBreaker;
    
    public ResilientRedisService() {
        CircuitBreakerConfig config = CircuitBreakerConfig.custom()
            .failureRateThreshold(50) // Открывать при 50% ошибок
            .waitDurationInOpenState(Duration.ofSeconds(30)) // Ждать 30 сек
            .slidingWindowSize(100) // Окно из 100 запросов
            .permittedNumberOfCallsInHalfOpenState(10)
            .automaticTransitionFromOpenToHalfOpenEnabled(true)
            .build();
        
        CircuitBreakerRegistry registry = CircuitBreakerRegistry.of(config);
        this.circuitBreaker = registry.circuitBreaker("redis");
        
        // Логирование событий circuit breaker
        circuitBreaker.getEventPublisher()
            .onStateTransition(event -> 
                log.warn("Circuit breaker state transition: {} -> {}",
                    event.getStateTransition().getFromState(),
                    event.getStateTransition().getToState()
                )
            )
            .onError(event ->
                log.error("Circuit breaker error: {}", event.getThrowable().getMessage())
            );
    }
    
    public void writeMarketData(String ticker, MarketData data) {
        Try.of(() -> circuitBreaker.executeSupplier(() ->
            retryTemplate.execute(context -> {
                try {
                    // Пишем в Redis
                    redisTemplate.opsForHash().put(
                        "market:latest",
                        ticker,
                        serializeMarketData(data)
                    );
                    
                    // Публикуем в Stream
                    redisTemplate.opsForStream().add(
                        StreamRecords.newRecord()
                            .ofObject(data)
                            .withStreamKey("stream:" + ticker)
                    );
                    
                    return null;
                    
                } catch (RedisConnectionFailureException e) {
                    log.error("Redis connection failed for ticker: {}", ticker);
                    throw e; // Retry
                    
                } catch (Exception e) {
                    log.error("Unexpected error writing to Redis: {}", e.getMessage());
                    throw e;
                }
            })
        )).onFailure(throwable -> {
            // Circuit breaker открыт или все retry исчерпаны
            handleFailedWrite(ticker, data, throwable);
        });
    }
    
    private void handleFailedWrite(String ticker, MarketData data, Throwable error) {
        // 1. Записываем в Dead Letter Queue
        sendToDeadLetterQueue(ticker, data, error);
        
        // 2. Инкрементируем метрику
        registry.counter("redis.write.failed", "ticker", ticker).increment();
        
        // 3. Отправляем alert
        if (shouldAlert(ticker, error)) {
            sendAlert(
                "CRITICAL",
                "Redis write failed for ticker: " + ticker,
                error.getMessage()
            );
        }
        
        // 4. Fallback: пишем в локальный буфер для последующей отправки
        localBuffer.add(new FailedWrite(ticker, data, Instant.now()));
    }
}

// ============================================
// Dead Letter Queue
// ============================================

@Service
public class DeadLetterQueueService {
    
    @Autowired
    private KafkaTemplate<String, FailedMessage> kafkaTemplate;
    
    public void send(String ticker, MarketData data, Throwable error) {
        FailedMessage message = FailedMessage.builder()
            .ticker(ticker)
            .data(data)
            .error(error.getMessage())
            .stackTrace(getStackTrace(error))
            .timestamp(Instant.now())
            .retryCount(0)
            .build();
        
        kafkaTemplate.send("dlq-market-data", ticker, message);
        
        log.error("Sent to DLQ: ticker={}, error={}", ticker, error.getMessage());
    }
}

// ============================================
// DLQ Consumer для повторной обработки
// ============================================

@Service
public class DeadLetterQueueConsumer {
    
    @Autowired
    private ResilientRedisService redisService;
    
    @KafkaListener(topics = "dlq-market-data", groupId = "dlq-processor")
    public void processDLQ(FailedMessage message) {
        if (message.getRetryCount() < 3) {
            // Пробуем еще раз через некоторое время
            try {
                Thread.sleep(Duration.ofMinutes(message.getRetryCount() + 1).toMillis());
                
                redisService.writeMarketData(message.getTicker(), message.getData());
                
                log.info("Successfully recovered message from DLQ: {}", message.getTicker());
                
            } catch (Exception e) {
                // Увеличиваем retry count и отправляем обратно в DLQ
                message.setRetryCount(message.getRetryCount() + 1);
                kafkaTemplate.send("dlq-market-data", message.getTicker(), message);
            }
        } else {
            // После 3 попыток отправляем в permanent failure queue
            kafkaTemplate.send("permanent-failures", message.getTicker(), message);
            
            sendAlert(
                "CRITICAL",
                "Permanent failure for ticker: " + message.getTicker(),
                "Failed after 3 retry attempts"
            );
        }
    }
}
```

### 3.2 Обработка сбоев реплик

```java
// ============================================
// Replica Health Monitor
// ============================================

@Service
public class ReplicaHealthMonitor {
    
    @Autowired
    private StringRedisTemplate redisTemplate;
    
    @Autowired
    private DiscoveryClient discoveryClient;
    
    @Value("${replica.id}")
    private String replicaId;
    
    @Scheduled(fixedRate = 5000) // Каждые 5 секунд
    public void publishHeartbeat() {
        Heartbeat heartbeat = Heartbeat.builder()
            .replicaId(replicaId)
            .timestamp(Instant.now())
            .portfolioCount(portfolios.size())
            .tickerCount(tickerToUsers.size())
            .cpuUsage(getCpuUsage())
            .memoryUsage(getMemoryUsage())
            .build();
        
        redisTemplate.opsForValue().set(
            "heartbeat:" + replicaId,
            serializeHeartbeat(heartbeat),
            10, TimeUnit.SECONDS // TTL 10 секунд
        );
    }
    
    @Scheduled(fixedRate = 10000) // Каждые 10 секунд
    public void checkReplicasHealth() {
        // Получаем список всех реплик из Kubernetes
        List<ServiceInstance> instances = discoveryClient.getInstances("analytics-service");
        
        List<String> deadReplicas = new ArrayList<>();
        
        for (ServiceInstance instance : instances) {
            String instanceId = instance.getMetadata().get("replica-id");
            
            String heartbeat = redisTemplate.opsForValue().get("heartbeat:" + instanceId);
            
            if (heartbeat == null) {
                deadReplicas.add(instanceId);
            }
        }
        
        if (!deadReplicas.isEmpty()) {
            log.error("Dead replicas detected: {}", deadReplicas);
            handleDeadReplicas(deadReplicas);
        }
    }
    
    private void handleDeadReplicas(List<String> deadReplicas) {
        deadReplicas.forEach(replicaId -> {
            // 1. Получаем список тикеров, на которые была подписана мёртвая реплика
            String subscriptions = (String) redisTemplate.opsForHash()
                .get("subscriptions:replicas", replicaId);
            
            if (subscriptions != null) {
                Set<String> tickers = Set.of(subscriptions.split(","));
                
                log.warn("Replica {} was subscribed to {} tickers, redistributing...",
                    replicaId, tickers.size());
                
                // 2. Находим живые реплики для redistribution
                List<String> aliveReplicas = findAliveReplicas();
                
                // 3. Перераспределяем тикеры
                redistributeTickers(tickers, aliveReplicas);
                
                // 4. Удаляем подписки мёртвой реплики
                redisTemplate.opsForHash().delete("subscriptions:replicas", replicaId);
                
                // 5. Отправляем alert
                sendAlert(
                    "WARNING",
                    "Replica failure detected: " + replicaId,
                    "Subscriptions redistributed to other replicas"
                );
            }
        });
    }
    
    private void redistributeTickers(Set<String> tickers, List<String> aliveReplicas) {
        // Простое распределение round-robin
        int index = 0;
        for (String ticker : tickers) {
            String targetReplica = aliveReplicas.get(index % aliveReplicas.size());
            
            // Отправляем команду реплике подписаться на ticker
            redisTemplate.convertAndSen
            ("replica-commands:" + targetReplica,
                new SubscribeCommand(ticker)
            );
            
            index++;
        }
    }
}

// ============================================
// Graceful Shutdown
// ============================================

@Component
public class GracefulShutdownHandler {
    
    @Autowired
    private StringRedisTemplate redisTemplate;
    
    @Value("${replica.id}")
    private String replicaId;
    
    @PreDestroy
    public void onShutdown() {
        log.info("Replica {} shutting down gracefully...", replicaId);
        
        try {
            // 1. Прекращаем принимать новые запросы
            stopAcceptingNewRequests();
            
            // 2. Завершаем обработку текущих запросов
            waitForInFlightRequests(Duration.ofSeconds(30));
            
            // 3. Отписываемся от всех Redis Streams
            unsubscribeFromAllStreams();
            
            // 4. Удаляем наши подписки из Redis
            redisTemplate.opsForHash().delete("subscriptions:replicas", replicaId);
            
            // 5. Удаляем heartbeat
            redisTemplate.delete("heartbeat:" + replicaId);
            
            log.info("Replica {} shutdown complete", replicaId);
            
        } catch (Exception e) {
            log.error("Error during graceful shutdown", e);
        }
    }
    
    private void waitForInFlightRequests(Duration timeout) {
        long endTime = System.currentTimeMillis() + timeout.toMillis();
        
        while (System.currentTimeMillis() < endTime && hasInFlightRequests()) {
            try {
                Thread.sleep(100);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                break;
            }
        }
        
        if (hasInFlightRequests()) {
            log.warn("Shutdown timeout reached, {} requests still in flight",
                getInFlightRequestCount());
        }
    }
}
```

## 4. Alerting

```yaml
# alertmanager.yml
route:
  group_by: ['alertname', 'service']
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 12h
  receiver: 'team-pager'
  routes:
  - match:
      severity: critical
    receiver: 'team-pager'
    continue: true
  - match:
      severity: warning
    receiver: 'team-slack'

receivers:
- name: 'team-pager'
  pagerduty_configs:
  - service_key: '<your-pagerduty-key>'
    description: '{{ .GroupLabels.alertname }}: {{ .CommonAnnotations.summary }}'

- name: 'team-slack'
  slack_configs:
  - api_url: '<your-slack-webhook>'
    channel: '#trading-platform-alerts'
    title: '{{ .GroupLabels.alertname }}'
    text: '{{ range .Alerts }}{{ .Annotations.description }}{{ end }}'

inhibit_rules:
- source_match:
    severity: 'critical'
  target_match:
    severity: 'warning'
  equal: ['alertname', 'service']
```

```yaml
# prometheus-rules.yml
groups:
- name: portfolio_analytics
  interval: 30s
  rules:
  
  # Высокая error rate
  - alert: HighErrorRate
    expr: |
      sum(rate(portfolio_updates_failed_total[5m])) 
      / 
      sum(rate(portfolio_updates_total[5m])) 
      * 100 > 5
    for: 2m
    labels:
      severity: critical
    annotations:
      summary: "High portfolio update error rate"
      description: "Error rate is {{ $value }}% (threshold: 5%)"
  
  # Высокая latency
  - alert: HighLatency
    expr: |
      histogram_quantile(0.99, 
        rate(portfolio_update_duration_bucket[5m])
      ) > 1
    for: 5m
    labels:
      severity: warning
    annotations:
      summary: "High portfolio update latency"
      description: "P99 latency is {{ $value }}s (threshold: 1s)"
  
  # Redis недоступен
  - alert: RedisDown
    expr: up{job="redis"} == 0
    for: 1m
    labels:
      severity: critical
    annotations:
      summary: "Redis is down"
      description: "Redis instance {{ $labels.instance }} is unreachable"
  
  # Большой lag в Redis Streams
  - alert: HighStreamLag
    expr: redis_stream_lag > 1000
    for: 3m
    labels:
      severity: warning
    annotations:
      summary: "High Redis Stream lag detected"
      description: "Stream lag for {{ $labels.ticker }} is {{ $value }} (threshold: 1000)"
  
  # Устаревшие данные
  - alert: StaleMarketData
    expr: |
      (time() - market_data_latest_timestamp) > 10
    for: 1m
    labels:
      severity: critical
    annotations:
      summary: "Stale market data detected"
      description: "Market data is {{ $value }}s old (threshold: 10s)"
  
  # Высокое использование памяти
  - alert: HighMemoryUsage
    expr: jvm_memory_usage_percent > 90
    for: 5m
    labels:
      severity: warning
    annotations:
      summary: "High memory usage"
      description: "Memory usage is {{ $value }}% on {{ $labels.instance }}"
  
  # Много мёртвых реплик
  - alert: MultipleReplicasDown
    expr: |
      count(up{job="analytics-service"} == 0) > 3
    for: 2m
    labels:
      severity: critical
    annotations:
      summary: "Multiple Analytics Service replicas are down"
      description: "{{ $value }} replicas are unreachable"
  
  # Ingestion Service перегружен
  - alert: IngestionServiceOverloaded
    expr: |
      rate(market_data_ticks_received_total[1m]) 
      / 
      rate(market_data_ticks_processed_total[1m]) 
      > 1.5
    for: 3m
    labels:
      severity: warning
    annotations:
      summary: "Ingestion service is falling behind"
      description: "Receiving {{ $value }}x more data than can be processed"
```

## 5. Logging

```java
// ============================================
// Structured Logging
// ============================================

@Slf4j
@Service
public class StructuredLoggingService {
    
    public void logMarketDataProcessed(String ticker, MarketData data, long processingTime) {
        // Используем structured logging (JSON format)
        MDC.put("ticker", ticker);
        MDC.put("price", String.valueOf(data.getPrice()));
        MDC.put("volume", String.valueOf(data.getVolume()));
        MDC.put("processing_time_ms", String.valueOf(processingTime));
        MDC.put("event_type", "market_data_processed");
        
        log.info("Market data processed successfully");
        
        MDC.clear();
    }
    
    public void logPortfolioUpdate(String userId, Portfolio portfolio, 
                                    String ticker, double oldValue, double newValue) {
        MDC.put("user_id", userId);
        MDC.put("ticker", ticker);
        MDC.put("old_value", String.valueOf(oldValue));
        MDC.put("new_value", String.valueOf(newValue));
        MDC.put("total_value", String.valueOf(portfolio.getTotalValue()));
        MDC.put("total_pnl", String.valueOf(portfolio.getTotalPnL()));
        MDC.put("event_type", "portfolio_updated");
        
        log.info("Portfolio updated");
        
        MDC.clear();
    }
    
    public void logError(String operation, Throwable error, Map<String, String> context) {
        context.forEach(MDC::put);
        MDC.put("operation", operation);
        MDC.put("error_type", error.getClass().getSimpleName());
        MDC.put("event_type", "error");
        
        log.error("Operation failed: " + operation, error);
        
        MDC.clear();
    }
}

// ============================================
// Logback Configuration (logback-spring.xml)
// ============================================
```

```xml
<configuration>
    <appender name="CONSOLE" class="ch.qos.logback.core.ConsoleAppender">
        <encoder class="net.logstash.logback.encoder.LogstashEncoder">
            <includeContext>true</includeContext>
            <includeMdc>true</includeMdc>
            <includeStructuredArguments>true</includeStructuredArguments>
            <fieldNames>
                <timestamp>@timestamp</timestamp>
                <message>message</message>
                <logger>logger_name</logger>
                <thread>thread_name</thread>
                <level>level</level>
                <stackTrace>stack_trace</stackTrace>
            </fieldNames>
        </encoder>
    </appender>
    
    <appender name="FILE" class="ch.qos.logback.core.rolling.RollingFileAppender">
        <file>/var/log/analytics-service/application.log</file>
        <rollingPolicy class="ch.qos.logback.core.rolling.TimeBasedRollingPolicy">
            <fileNamePattern>/var/log/analytics-service/application.%d{yyyy-MM-dd}.log.gz</fileNamePattern>
            <maxHistory>30</maxHistory>
            <totalSizeCap>10GB</totalSizeCap>
        </rollingPolicy>
        <encoder class="net.logstash.logback.encoder.LogstashEncoder"/>
    </appender>
    
    <!-- Отдельный файл для ошибок -->
    <appender name="ERROR_FILE" class="ch.qos.logback.core.rolling.RollingFileAppender">
        <file>/var/log/analytics-service/error.log</file>
        <filter class="ch.qos.logback.classic.filter.ThresholdFilter">
            <level>ERROR</level>
        </filter>
        <rollingPolicy class="ch.qos.logback.core.rolling.TimeBasedRollingPolicy">
            <fileNamePattern>/var/log/analytics-service/error.%d{yyyy-MM-dd}.log.gz</fileNamePattern>
            <maxHistory>90</maxHistory>
        </rollingPolicy>
        <encoder class="net.logstash.logback.encoder.LogstashEncoder"/>
    </appender>
    
    <root level="INFO">
        <appender-ref ref="CONSOLE"/>
        <appender-ref ref="FILE"/>
        <appender-ref ref="ERROR_FILE"/>
    </root>
</configuration>
```

## 6. Distributed Tracing

```java
// ============================================
// Jaeger Tracing
// ============================================

@Configuration
public class TracingConfig {
    
    @Bean
    public io.opentracing.Tracer jaegerTracer() {
        return Configuration.fromEnv("analytics-service")
            .withSampler(
                Configuration.SamplerConfiguration.fromEnv()
                    .withType("probabilistic")
                    .withParam(0.1) // Sample 10% of requests
            )
            .withReporter(
                Configuration.ReporterConfiguration.fromEnv()
                    .withLogSpans(true)
                    .withMaxQueueSize(10000)
            )
            .getTracer();
    }
}

@Service
public class TracedAnalyticsService {
    
    @Autowired
    private Tracer tracer;
    
    public void handleMarketDataUpdate(String ticker, MarketData data) {
        Span span = tracer.buildSpan("handle_market_data")
            .withTag("ticker", ticker)
            .withTag("price", data.getPrice())
            .start();
        
        try (Scope scope = tracer.activateSpan(span)) {
            
            // Child span для получения affected users
            Span getUsersSpan = tracer.buildSpan("get_affected_users")
                .asChildOf(span)
                .start();
            
            Set<String> users = tickerToUsers.get(ticker);
            getUsersSpan.setTag("user_count", users.size());
            getUsersSpan.finish();
            
            // Child span для обновления портфелей
            Span updateSpan = tracer.buildSpan("update_portfolios")
                .asChildOf(span)
                .start();
            
            users.forEach(userId -> {
                updatePortfolio(userId, ticker, data);
            });
            
            updateSpan.finish();
            
        } catch (Exception e) {
            span.setTag("error", true);
            span.log(Map.of(
                "event", "error",
                "error.object", e,
                "message", e.getMessage()
            ));
            throw e;
        } finally {
            span.finish();
        }
    }
}
```

Это комплексная система мониторинга и обработки ошибок. Хотите, чтобы я показал:
1. Как настроить автоматическое масштабирование на основе этих метрик?
2. Disaster recovery сценарии?
3. Load testing и capacity planning?

Хотите, чтобы я показал, как организовать мониторинг и обработку ошибок для этой архитектуры?
