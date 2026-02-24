# Подключение Spring Boot приложения к Kafka как Consumer в Kubernetes + Istio

## 1. Зависимости (pom.xml)

```xml
<dependencies>
    <!-- Spring Kafka -->
    <dependency>
        <groupId>org.springframework.kafka</groupId>
        <artifactId>spring-kafka</artifactId>
    </dependency>
    
    <!-- Spring Boot Starter -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter</artifactId>
    </dependency>
    
    <!-- Lombok (опционально) -->
    <dependency>
        <groupId>org.projectlombok</groupId>
        <artifactId>lombok</artifactId>
        <optional>true</optional>
    </dependency>
</dependencies>
```

---

## 2. Структура конфигурации

### application.yml

```yaml
app:
  kafka:
    request-topic: ${KAFKA_REQUEST_TOPIC:CALYPSO.ADAPTEREXCHANGE_FXSETTLEMENT_EVENT.V1}
    brokers: ${KAFKA_BROKERS:broker1:9092,broker2:9092,broker3:9092}
    group-id: ${KAFKA_GROUP_ID:gtp_synapse_CALYPSO.ADAPTEREXCHANGE_FXSETTLEMENT_EVENT.V1_adapterexchange}
    consumers-count: ${KAFKA_CONSUMERS_COUNT:1}
    max-poll-records: ${KAFKA_MAX_POLL_RECORDS:1}
    max-poll-interval-ms: ${KAFKA_MAX_POLL_INTERVAL_MS:240000}
    security-enabled: ${KAFKA_SECURITY_ENABLED:false}
    hot-swap-parameters:
      auto-offset-reset: ${KAFKA_AUTO_OFFSET_RESET:latest}
    # SSL параметры (загружаются из mounted secrets)
    ssl-protocol: ${SSL_PROTOCOL:}
    ssl-truststore-location: ${SSL_TRUSTSTORE_LOCATION:}
    ssl-truststore-password: ${SSL_TRUSTSTORE_PASSWORD:}
    ssl-keystore-location: ${SSL_KEYSTORE_LOCATION:}
    ssl-keystore-password: ${SSL_KEYSTORE_PASSWORD:}
    ssl-key-password: ${SSL_KEY_PASSWORD:}
    ssl-key-manager-algorithm: ${SSL_KEY_MANAGER_ALGORITHM:}
    ssl-endpoint-algorithm: ${SSL_ENDPOINT_ALGORITHM:}
```

---

## 3. Properties класс

```java
package com.example.config;

import lombok.Data;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

@Data
@Component
@ConfigurationProperties(prefix = "app.kafka")
public class KafkaProperties {

    private String requestTopic;
    private String brokers;
    private String groupId;
    private int consumersCount = 1;
    private int maxPollRecords = 1;
    private long maxPollIntervalMs = 240_000L;
    private boolean securityEnabled = false;

    // SSL
    private String sslProtocol;
    private String sslTruststoreLocation;
    private String sslTruststorePassword;
    private String sslKeystoreLocation;
    private String sslKeystorePassword;
    private String sslKeyPassword;
    private String sslKeyManagerAlgorithm;
    private String sslEndpointAlgorithm;

    private HotSwapParameters hotSwapParameters = new HotSwapParameters();

    @Data
    public static class HotSwapParameters {
        private String autoOffsetReset = "latest";
    }
}
```

---

## 4. Kafka Configuration

```java
package com.example.config;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.apache.kafka.clients.CommonClientConfigs;
import org.apache.kafka.clients.consumer.ConsumerConfig;
import org.apache.kafka.common.config.SslConfigs;
import org.apache.kafka.common.serialization.StringDeserializer;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.kafka.config.ConcurrentKafkaListenerContainerFactory;
import org.springframework.kafka.core.ConsumerFactory;
import org.springframework.kafka.core.DefaultKafkaConsumerFactory;
import org.springframework.kafka.listener.ContainerProperties;
import org.springframework.util.StringUtils;

import java.util.HashMap;
import java.util.Map;

@Slf4j
@Configuration
@RequiredArgsConstructor
public class KafkaConsumerConfig {

    private final KafkaProperties kafkaProperties;

    @Bean
    public ConsumerFactory<String, String> consumerFactory() {
        Map<String, Object> props = buildConsumerProperties();
        log.info("Creating Kafka ConsumerFactory with brokers: {}, groupId: {}, topic: {}",
                kafkaProperties.getBrokers(),
                kafkaProperties.getGroupId(),
                kafkaProperties.getRequestTopic());
        return new DefaultKafkaConsumerFactory<>(props);
    }

    @Bean
    public ConcurrentKafkaListenerContainerFactory<String, String> kafkaListenerContainerFactory(
            ConsumerFactory<String, String> consumerFactory) {

        ConcurrentKafkaListenerContainerFactory<String, String> factory =
                new ConcurrentKafkaListenerContainerFactory<>();

        factory.setConsumerFactory(consumerFactory);

        // Количество потоков-консюмеров
        factory.setConcurrency(kafkaProperties.getConsumersCount());

        // Режим подтверждения оффсетов — вручную для надёжности
        factory.getContainerProperties().setAckMode(ContainerProperties.AckMode.MANUAL_IMMEDIATE);

        log.info("KafkaListenerContainerFactory configured with concurrency: {}",
                kafkaProperties.getConsumersCount());

        return factory;
    }

    private Map<String, Object> buildConsumerProperties() {
        Map<String, Object> props = new HashMap<>();

        // Основные параметры
        props.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, kafkaProperties.getBrokers());
        props.put(ConsumerConfig.GROUP_ID_CONFIG, kafkaProperties.getGroupId());
        props.put(ConsumerConfig.MAX_POLL_RECORDS_CONFIG, kafkaProperties.getMaxPollRecords());
        props.put(ConsumerConfig.MAX_POLL_INTERVAL_MS_CONFIG, (int) kafkaProperties.getMaxPollIntervalMs());
        props.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG,
                kafkaProperties.getHotSwapParameters().getAutoOffsetReset());

        // Десериализаторы
        props.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class);
        props.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class);

        // Отключаем автокоммит — управляем вручную
        props.put(ConsumerConfig.ENABLE_AUTO_COMMIT_CONFIG, false);

        // Session и heartbeat таймауты
        props.put(ConsumerConfig.SESSION_TIMEOUT_MS_CONFIG, 30_000);
        props.put(ConsumerConfig.HEARTBEAT_INTERVAL_MS_CONFIG, 10_000);

        // SSL если включён
        if (kafkaProperties.isSecurityEnabled()) {
            applySslConfig(props);
        }

        return props;
    }

    private void applySslConfig(Map<String, Object> props) {
        log.info("Applying SSL configuration for Kafka");

        props.put(CommonClientConfigs.SECURITY_PROTOCOL_CONFIG, "SSL");

        if (StringUtils.hasText(kafkaProperties.getSslProtocol())) {
            props.put(SslConfigs.SSL_PROTOCOL_CONFIG, kafkaProperties.getSslProtocol());
        }
        if (StringUtils.hasText(kafkaProperties.getSslTruststoreLocation())) {
            props.put(SslConfigs.SSL_TRUSTSTORE_LOCATION_CONFIG, kafkaProperties.getSslTruststoreLocation());
        }
        if (StringUtils.hasText(kafkaProperties.getSslTruststorePassword())) {
            props.put(SslConfigs.SSL_TRUSTSTORE_PASSWORD_CONFIG, kafkaProperties.getSslTruststorePassword());
        }
        if (StringUtils.hasText(kafkaProperties.getSslKeystoreLocation())) {
            props.put(SslConfigs.SSL_KEYSTORE_LOCATION_CONFIG, kafkaProperties.getSslKeystoreLocation());
        }
        if (StringUtils.hasText(kafkaProperties.getSslKeystorePassword())) {
            props.put(SslConfigs.SSL_KEYSTORE_PASSWORD_CONFIG, kafkaProperties.getSslKeystorePassword());
        }
        if (StringUtils.hasText(kafkaProperties.getSslKeyPassword())) {
            props.put(SslConfigs.SSL_KEY_PASSWORD_CONFIG, kafkaProperties.getSslKeyPassword());
        }
        if (StringUtils.hasText(kafkaProperties.getSslKeyManagerAlgorithm())) {
            props.put(SslConfigs.SSL_KEYMANAGER_ALGORITHM_CONFIG, kafkaProperties.getSslKeyManagerAlgorithm());
        }
        if (StringUtils.hasText(kafkaProperties.getSslEndpointAlgorithm())) {
            props.put(SslConfigs.SSL_ENDPOINT_IDENTIFICATION_ALGORITHM_CONFIG,
                    kafkaProperties.getSslEndpointAlgorithm());
        }
    }
}
```

---

## 5. Kafka Consumer (Listener)

```java
package com.example.kafka;

import lombok.extern.slf4j.Slf4j;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.kafka.support.Acknowledgment;
import org.springframework.kafka.support.KafkaHeaders;
import org.springframework.messaging.handler.annotation.Header;
import org.springframework.stereotype.Component;

@Slf4j
@Component
public class FxSettlementEventConsumer {

    @KafkaListener(
            topics = "${app.kafka.request-topic}",
            groupId = "${app.kafka.group-id}",
            containerFactory = "kafkaListenerContainerFactory"
    )
    public void consume(
            ConsumerRecord<String, String> record,
            Acknowledgment acknowledgment,
            @Header(KafkaHeaders.RECEIVED_TOPIC) String topic,
            @Header(KafkaHeaders.RECEIVED_PARTITION) int partition,
            @Header(KafkaHeaders.OFFSET) long offset) {

        log.info("Received message: topic={}, partition={}, offset={}, key={}",
                topic, partition, offset, record.key());

        try {
            processMessage(record.value());

            // Подтверждаем оффсет только после успешной обработки
            acknowledgment.acknowledge();

            log.info("Message processed and acknowledged: offset={}", offset);

        } catch (Exception e) {
            log.error("Error processing message at offset={}: {}", offset, e.getMessage(), e);
            // Не подтверждаем — сообщение будет перечитано
            // Здесь можно добавить логику retry / DLQ
            throw e;
        }
    }

    private void processMessage(String payload) {
        log.debug("Processing payload: {}", payload);
        // Ваша бизнес-логика
    }
}
```

---

## 6. Kubernetes ConfigMap

```yaml
# configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-app-config
  namespace: my-namespace
data:
  application.yml: |
    app:
      kafka:
        request-topic: CALYPSO.ADAPTEREXCHANGE_FXSETTLEMENT_EVENT.V1
        brokers: broker1.kafka.svc.cluster.local:9092,broker2.kafka.svc.cluster.local:9092
        group-id: gtp_synapse_CALYPSO.ADAPTEREXCHANGE_FXSETTLEMENT_EVENT.V1_adapterexchange
        consumers-count: 1
        max-poll-records: 1
        max-poll-interval-ms: 240000
        security-enabled: false
        hot-swap-parameters:
          auto-offset-reset: latest
```

---

## 7. Kubernetes Secret (для SSL)

```yaml
# secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: kafka-ssl-secrets
  namespace: my-namespace
type: Opaque
data:
  ssl-secrets.yml: <base64-encoded-content>
```

---

## 8. Deployment с Istio

```yaml
# deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-kafka-consumer
  namespace: my-namespace
  labels:
    app: my-kafka-consumer
    version: v1
spec:
  replicas: 1
  selector:
    matchLabels:
      app: my-kafka-consumer
  template:
    metadata:
      labels:
        app: my-kafka-consumer
        version: v1
      annotations:
        # Istio sidecar инъекция
        sidecar.istio.io/inject: "true"
        # ВАЖНО: исключаем Kafka порты из перехвата Istio
        # иначе Istio будет перехватывать TCP трафик к Kafka
        traffic.sidecar.istio.io/excludeOutboundPorts: "9092,9093"
        traffic.sidecar.istio.io/excludeInboundPorts: "9092,9093"
    spec:
      containers:
        - name: my-kafka-consumer
          image: my-registry/my-kafka-consumer:latest
          ports:
            - containerPort: 8080
          env:
            - name: SPRING_CONFIG_LOCATION
              value: "classpath:/application.yml,file:/config/application.yml,file:/mnt/ssl/ssl-secrets.yml"
          volumeMounts:
            # Монтируем ConfigMap
            - name: app-config
              mountPath: /config
              readOnly: true
            # Монтируем SSL секреты
            - name: ssl-secrets
              mountPath: /mnt/ssl
              readOnly: true
          resources:
            requests:
              memory: "512Mi"
              cpu: "250m"
            limits:
              memory: "1Gi"
              cpu: "500m"
          livenessProbe:
            httpGet:
              path: /actuator/health/liveness
              port: 8080
            initialDelaySeconds: 60
            periodSeconds: 30
          readinessProbe:
            httpGet:
              path: /actuator/health/readiness
              port: 8080
            initialDelaySeconds: 30
            periodSeconds: 10
      volumes:
        - name: app-config
          configMap:
            name: my-app-config
        - name: ssl-secrets
          secret:
            secretName: kafka-ssl-secrets
```

---

## 9. Istio — исключение Kafka из mesh (важно!)

```yaml
# istio-sidecar.yaml
# Вариант 1: через аннотации пода (уже указано в Deployment выше)

# Вариант 2: через ServiceEntry — регистрируем внешний Kafka в mesh
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: kafka-external
  namespace: my-namespace
spec:
  hosts:
    - broker1.kafka.example.com
    - broker2.kafka.example.com
  ports:
    - number: 9092
      name: tcp-kafka
      protocol: TCP
    - number: 9093
      name: tcp-kafka-ssl
      protocol: TCP
  location: MESH_EXTERNAL
  resolution: DNS
```

```yaml
# Если Kafka внутри кластера — DestinationRule
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: kafka-destination
  namespace: my-namespace
spec:
  host: kafka.kafka-namespace.svc.cluster.local
  trafficPolicy:
    tls:
      mode: DISABLE  # Kafka сам управляет TLS
```

---

## 10. Actuator для health checks

```yaml
# в application.yml добавить
management:
  endpoints:
    web:
      exposure:
        include: health,info,metrics
  endpoint:
    health:
      show-details: always
      probes:
        enabled: true
  health:
    kafka:
      enabled: true
```

---

## Ключевые моменты по Istio + Kafka

```
┌─────────────────────────────────────────────────────────┐
│  ПРОБЛЕМА: Istio перехватывает TCP трафик к Kafka       │
│                                                         │
│  РЕШЕНИЕ 1 (простое):                                   │
│  Аннотации на поде:                                     │
│  traffic.sidecar.istio.io/excludeOutboundPorts: "9092"  │
│                                                         │
│  РЕШЕНИЕ 2 (правильное):                                │
│  ServiceEntry для регистрации Kafka в mesh              │
│  + DestinationRule с tls.mode: DISABLE                  │
│  (если Kafka сам управляет TLS/mTLS)                    │
│                                                         │
│  РЕШЕНИЕ 3 (если Kafka в том же кластере):              │
│  PeerAuthentication с mode: PERMISSIVE для namespace    │
│  где живёт Kafka                                        │
└─────────────────────────────────────────────────────────┘
```

---

## Итоговая структура проекта

```
src/
├── main/
│   ├── java/com/example/
│   │   ├── config/
│   │   │   ├── KafkaProperties.java
│   │   │   └── KafkaConsumerConfig.java
│   │   ├── kafka/
│   │   │   └── FxSettlementEventConsumer.java
│   │   └── Application.java
│   └── resources/
│       └── application.yml
k8s/
├── configmap.yaml
├── secret.yaml
├── deployment.yaml
├── service-entry.yaml
└── destination-rule.yaml
```
