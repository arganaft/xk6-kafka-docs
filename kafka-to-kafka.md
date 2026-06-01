## Короткий вывод

Да, проблемы могут быть, даже если `mvn test` сейчас зелёный.

Главные риски в твоём `POM` при переходе на `spring-boot-starter-parent:4.0.6`:

1. **Java 21 не обязательна**: Spring Boot `4.0.6` требует минимум **Java 17**. Если оставить `<java.version>17</java.version>` и не использовать API Java 21, приложения на Java 17 смогут запускаться.
2. **Но Spring Boot 4 и Spring Boot 3 смешивать нельзя** в одном runtime-класспате. Если этот артефакт используется как стартер/библиотека в старых приложениях на Spring Boot 3, возможны конфликты.
3. **Camel `4.10.7` — главный подозрительный момент**. Для Spring Boot 4 нужна ветка Camel, где явно добавлена поддержка Boot 4. По состоянию на 2026 это минимум **Camel `4.19.0`**, лучше брать актуальную `4.20.0`, если она у вас доступна.
4. **`logstash-logback-encoder:8.0` несовместим с Jackson 3**, который приходит со Spring Boot 4. Нужен `logstash-logback-encoder:9.0`.
5. **`kafka-clients:3.9.1` лучше не пинить вручную**, если Spring Boot 4 уже управляет более новой безопасной версией Kafka. Ручной downgrade до `3.9.1` может конфликтовать с Camel/Spring Boot 4.
6. **`camel-test-spring-junit5` лучше заменить на `camel-test-spring-junit6`**, если переходишь на Camel-ветку под Spring Boot 4.
7. `spring-boot-starter-web` в Spring Boot 4 лучше заменить на **`spring-boot-starter-webmvc`**.

---

## Нужно ли обновлять Java до 21 в других приложениях?

**Нет, не обязательно.**

Spring Boot `4.0.6` требует минимум **Java 17**. Значит, если:

- твой стартер собран с `<java.version>17</java.version>`;
- ты не используешь классы/API из Java 21;
- зависимости тоже не требуют Java 21;

то приложения на Java 17 технически могут продолжать работать.

Но есть важное уточнение:

> Java 17 достаточно для Spring Boot 4, но приложениям всё равно придётся быть совместимыми со Spring Boot 4, Spring Framework 7, Jackson 3, Jakarta EE 11 и новыми версиями зависимостей.

То есть проблема скорее не в Java, а в **экосистемной совместимости**.

---

## Что может сломаться незаметно

### 1. Старые приложения на Spring Boot 3

Если другие приложения используют этот артефакт как зависимость, а сами остаются на Spring Boot 3, возможны проблемы:

- разные версии `spring-core`, `spring-context`, `spring-web`;
- Spring Boot 3 тянет Spring Framework 6, а Boot 4 — Spring Framework 7;
- разные версии Jackson: Boot 3 обычно Jackson 2, Boot 4 — Jackson 3;
- разные Servlet API;
- разные версии Kafka;
- разные версии тестовой инфраструктуры.

Даже если Maven выберет одну версию через dependency mediation, это не значит, что всё совместимо. Можно получить:

- `NoSuchMethodError`;
- `ClassNotFoundException`;
- `NoClassDefFoundError`;
- ошибки автоконфигурации;
- несовместимость логирования;
- ошибки сериализации JSON;
- проблемы с Camel auto-configuration.

**Рекомендация:** если этот артефакт должен поддерживать Spring Boot 4, лучше поднять его major/minor версию явно, например:

```xml
<version>3.0.0-SNAPSHOT</version>
```

А старую ветку оставить для Spring Boot 3.

---

### 2. Apache Camel `4.10.7`

В твоём текущем POM:

```xml
<camel.version>4.10.7</camel.version>
```

Это плохо сочетается со Spring Boot 4.

Поддержка Spring Boot 4 в Camel появилась позже. По состоянию на 01.06.2026 безопаснее ориентироваться на:

```xml
<camel.version>4.20.0</camel.version>
```

или минимум:

```xml
<camel.version>4.19.0</camel.version>
```

Особенно важно заменить:

```xml
<artifactId>camel-test-spring-junit5</artifactId>
```

на:

```xml
<artifactId>camel-test-spring-junit6</artifactId>
```

---

### 3. `logstash-logback-encoder:8.0`

С Spring Boot 4 приходит Jackson 3. `logstash-logback-encoder:8.0` ориентирован на Jackson 2.

Нужно заменить:

```xml
<version>8.0</version>
```

на:

```xml
<version>9.0</version>
```

---

### 4. Ручной `kafka-clients:3.9.1`

Сейчас у тебя:

```xml
<kafka-clients.version>3.9.1</kafka-clients.version>
```

и ручная зависимость:

```xml
<dependency>
    <groupId>org.apache.kafka</groupId>
    <artifactId>kafka-clients</artifactId>
    <version>${kafka-clients.version}</version>
</dependency>
```

При Spring Boot 4 это потенциально опасно. Boot 4 сам управляет Kafka-зависимостями, и Camel новой версии тоже ожидает более новую экосистему.

Если причина была только CVE, то после перехода на Boot 4 надо проверить, какая версия Kafka управляется Boot `4.0.6`. Если она уже закрывает CVE, лучше **убрать ручной override**.

Если security-плагин всё равно требует конкретную версию, лучше задавать её через `dependencyManagement`, а не прямой runtime dependency.

---

### 5. `spring-boot-starter-web`

В Spring Boot 4 лучше использовать:

```xml
<artifactId>spring-boot-starter-webmvc</artifactId>
```

вместо:

```xml
<artifactId>spring-boot-starter-web</artifactId>
```

---

### 6. `logback-classic`

У тебя явно добавлен:

```xml
<dependency>
    <groupId>ch.qos.logback</groupId>
    <artifactId>logback-classic</artifactId>
</dependency>
```

Обычно он уже приходит через `spring-boot-starter-logging`, который подтягивается стартерами Spring Boot. Я бы убрал явную зависимость, если нет специальной причины.

---

## Как бы я переписал POM

Ниже вариант для **Spring Boot 4.0.6 + Java 17 + Camel 4.20.0**.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">

    <modelVersion>4.0.0</modelVersion>

    <parent>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-parent</artifactId>
        <version>4.0.6</version>
        <relativePath/>
    </parent>

    <groupId>ru.sberbank.syngtp</groupId>
    <artifactId>syngtp-kafka-to-kafka-template</artifactId>
    <version>3.0.0-SNAPSHOT</version>

    <name>KAFKA:KAFKA:TEMPLATE</name>
    <description>Service kafka-to-kafka with filter custom implementation</description>

    <properties>
        <java.version>17</java.version>

        <!-- Spring Boot 4 support starts in Camel 4.19.0. Prefer newer stable version if available. -->
        <camel.version>4.20.0</camel.version>

        <!-- Spring Boot 4 uses Jackson 3, so logstash-logback-encoder 9.x is required. -->
        <logstash-logback-encoder.version>9.0</logstash-logback-encoder.version>

        <commons-io.version>2.18.0</commons-io.version>

        <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
        <project.reporting.outputEncoding>UTF-8</project.reporting.outputEncoding>
    </properties>

    <scm>
        <url>https://stash.delta.sbrf.ru/projects/SYNGTP/repos/${project.artifactId}</url>
        <connection>scm:git:https://stash.delta.sbrf.ru/scm/syngtp/${project.artifactId}.git</connection>
        <developerConnection>scm:git:https://stash.delta.sbrf.ru/scm/syngtp/${project.artifactId}.git</developerConnection>
        <tag>HEAD</tag>
    </scm>

    <dependencyManagement>
        <dependencies>
            <!-- Manages Camel Spring Boot starters and Camel modules. -->
            <dependency>
                <groupId>org.apache.camel.springboot</groupId>
                <artifactId>camel-spring-boot-bom</artifactId>
                <version>${camel.version}</version>
                <type>pom</type>
                <scope>import</scope>
            </dependency>

            <!--
            Если security требует жёстко зафиксировать kafka-clients,
            лучше делать это здесь, а не отдельной compile dependency.

            Но по умолчанию я бы НЕ пинил kafka-clients вручную,
            а оставил версию из Spring Boot / Camel BOM.

            Пример, если всё-таки потребуется:

            <dependency>
                <groupId>org.apache.kafka</groupId>
                <artifactId>kafka-clients</artifactId>
                <version>...</version>
            </dependency>
            -->
        </dependencies>
    </dependencyManagement>

    <dependencies>
        <!-- Spring Boot -->
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-actuator</artifactId>
        </dependency>

        <!-- Spring MVC starter for Spring Boot 4 -->
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-webmvc</artifactId>
            <exclusions>
                <exclusion>
                    <groupId>org.springframework.boot</groupId>
                    <artifactId>spring-boot-starter-tomcat</artifactId>
                </exclusion>
            </exclusions>
        </dependency>

        <!-- Jetty instead of Tomcat -->
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-jetty</artifactId>
        </dependency>

        <!-- Camel -->
        <dependency>
            <groupId>org.apache.camel.springboot</groupId>
            <artifactId>camel-spring-boot-starter</artifactId>
        </dependency>

        <!-- Prefer Camel Spring Boot component starter instead of raw camel-kafka -->
        <dependency>
            <groupId>org.apache.camel.springboot</groupId>
            <artifactId>camel-kafka-starter</artifactId>
        </dependency>

        <!-- Lombok -->
        <dependency>
            <groupId>org.projectlombok</groupId>
            <artifactId>lombok</artifactId>
            <optional>true</optional>
        </dependency>

        <!-- Utils -->
        <dependency>
            <groupId>commons-io</groupId>
            <artifactId>commons-io</artifactId>
            <version>${commons-io.version}</version>
        </dependency>

        <!-- ELK / JSON logging. Version 9.x is needed for Jackson 3. -->
        <dependency>
            <groupId>net.logstash.logback</groupId>
            <artifactId>logstash-logback-encoder</artifactId>
            <version>${logstash-logback-encoder.version}</version>
        </dependency>

        <!-- Tests -->
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-webmvc-test</artifactId>
            <scope>test</scope>
        </dependency>

        <dependency>
            <groupId>org.apache.camel</groupId>
            <artifactId>camel-test-spring-junit6</artifactId>
            <scope>test</scope>
        </dependency>

        <dependency>
            <groupId>org.xmlunit</groupId>
            <artifactId>xmlunit-assertj</artifactId>
            <scope>test</scope>
        </dependency>
    </dependencies>

    <build>
        <plugins>
            <!-- Optional, but useful for executable Spring Boot application. -->
            <plugin>
                <groupId>org.springframework.boot</groupId>
                <artifactId>spring-boot-maven-plugin</artifactId>
            </plugin>

            <!-- Optional: fail fast on dependency problems. -->
            <plugin>
                <groupId>org.apache.maven.plugins</groupId>
                <artifactId>maven-enforcer-plugin</artifactId>
                <version>3.5.0</version>
                <executions>
                    <execution>
                        <id>enforce-dependencies</id>
                        <goals>
                            <goal>enforce</goal>
                        </goals>
                        <configuration>
                            <rules>
                                <requireJavaVersion>
                                    <version>[17,)</version>
                                </requireJavaVersion>

                                <dependencyConvergence/>

                                <requireUpperBoundDeps/>

                                <banDuplicatePomDependencyVersions/>
                            </rules>
                            <fail>true</fail>
                        </configuration>
                    </execution>
                </executions>
            </plugin>
        </plugins>
    </build>

</project>
```

---

## Если тебе всё-таки нужно явно зафиксировать `kafka-clients`

Я бы не добавлял его как обычную зависимость:

```xml
<dependency>
    <groupId>org.apache.kafka</groupId>
    <artifactId>kafka-clients</artifactId>
    <version>${kafka-clients.version}</version>
</dependency>
```

Лучше так:

```xml
<dependencyManagement>
    <dependencies>
        <dependency>
            <groupId>org.apache.camel.springboot</groupId>
            <artifactId>camel-spring-boot-bom</artifactId>
            <version>${camel.version}</version>
            <type>pom</type>
            <scope>import</scope>
        </dependency>

        <dependency>
            <groupId>org.apache.kafka</groupId>
            <artifactId>kafka-clients</artifactId>
            <version>${kafka-clients.version}</version>
        </dependency>
    </dependencies>
</dependencyManagement>
```

Но я бы делал это только после проверки:

```bash
mvn dependency:tree -Dincludes=org.apache.kafka:kafka-clients
```

---

## Как бы я тестировал миграцию

### 1. Проверка effective POM

```bash
mvn help:effective-pom -Doutput=target/effective-pom.xml
```

Смотрим:

- версии Spring;
- версии Camel;
- версии Kafka;
- версии Jackson;
- версии Logback;
- версии JUnit.

---

### 2. Проверка dependency tree

```bash
mvn dependency:tree
```

Отдельно:

```bash
mvn dependency:tree -Dincludes=org.springframework
mvn dependency:tree -Dincludes=org.apache.camel
mvn dependency:tree -Dincludes=org.apache.kafka
mvn dependency:tree -Dincludes=tools.jackson
mvn dependency:tree -Dincludes=com.fasterxml.jackson
mvn dependency:tree -Dincludes=ch.qos.logback
mvn dependency:tree -Dincludes=org.junit
```

Особенно важно проверить, что нет одновременной смеси:

- Spring Framework 6 и 7;
- Jackson 2 и Jackson 3;
- JUnit 5 и JUnit 6, если вы уже полностью мигрируете;
- разных веток Camel.

---

### 3. Проверка на Java 17

Обязательно прогнать сборку именно на JDK 17:

```bash
java -version
mvn clean verify
```

Если CI позволяет, я бы сделал matrix:

```text
JDK 17
JDK 21
```

Минимально обязательный — JDK 17.

---

### 4. Unit tests

```bash
mvn clean test
```

Но одного `test` мало. Он не гарантирует, что:

- Camel Kafka endpoint реально работает;
- Kafka client совместим;
- Jetty стартует;
- actuator endpoints доступны;
- JSON logging не падает на Jackson 3;
- старые приложения-потребители совместимы.

---

### 5. Integration tests с Kafka

Я бы добавил интеграционные тесты через Testcontainers.

Проверить сценарии:

- чтение из input topic;
- фильтрация сообщения;
- отправка в output topic;
- сохранение key;
- сохранение headers;
- бинарный payload;
- JSON payload;
- пустой payload;
- ошибка обработки;
- reconnect;
- consumer group;
- offset reset;
- несколько partitions.

Команды:

```bash
mvn clean verify
```

Или отдельный профиль:

```bash
mvn clean verify -Pintegration-tests
```

---

### 6. Smoke test приложения

Запустить приложение:

```bash
mvn spring-boot:run
```

Проверить actuator:

```bash
curl http://localhost:8080/actuator/health
```

Если порт другой — подставить свой.

---

### 7. Проверка логирования

Отдельно проверить, что `logstash-logback-encoder` реально стартует.

Типичные ошибки при несовместимости:

```text
ClassNotFoundException
NoClassDefFoundError
NoSuchMethodError
```

Особенно вокруг Jackson-классов.

---

### 8. Проверка потребителей стартера

Если этот модуль реально используется другими приложениями, я бы сделал минимум два тестовых consumer-проекта:

| Consumer app | Spring Boot | Java | Ожидание |
|---|---:|---:|---|
| `sample-boot4-app` | `4.0.6` | `17` | должен работать |
| `sample-boot3-app` | `3.x` | `17` | скорее всего не поддерживать |

Если нужно поддерживать Spring Boot 3 и 4 одновременно, лучше не пытаться делать это одним артефактом. Лучше иметь две ветки:

```text
2.x.x -> Spring Boot 3
3.x.x -> Spring Boot 4
```

---

## Что думаю про плагин, который валит сборку при разных версиях одной библиотеки

В целом — **это хорошая практика**, особенно для общего стартера/шаблона.

Но есть нюанс.

Maven сам по себе не кладёт в classpath две версии одного и того же artifact-а. Он выбирает одну версию по правилам dependency mediation. Поэтому проблема обычно не в том, что физически попадут две версии, а в том, что:

- одна библиотека была скомпилирована против версии A;
- в runtime Maven выбрал версию B;
- в итоге получаем `NoSuchMethodError`.

Поэтому такие проверки полезны.

Я бы использовал:

```xml
<dependencyConvergence/>
<requireUpperBoundDeps/>
<banDuplicatePomDependencyVersions/>
```

Но надо быть готовым, что после перехода на Boot 4 плагин начнёт честно находить конфликты, которые раньше были скрыты.

Особенно вероятные зоны:

- `jackson`;
- `logback`;
- `slf4j`;
- `kafka-clients`;
- `spring-*`;
- `jakarta.*`;
- `junit`;
- `mockito`;
- `byte-buddy`;
- `netty`.

Мой подход:

1. Сначала максимально полагаться на BOM-ы:
   - Spring Boot parent;
   - Camel Spring Boot BOM.
2. Не пинить вручную то, чем уже управляет Spring Boot.
3. Если нужно переопределять — делать это через `dependencyManagement`.
4. Каждое переопределение сопровождать комментарием: зачем оно нужно.
5. После каждого override прогонять `dependency:tree` и integration tests.

---

## Моё финальное мнение по твоей ситуации

Если просто заменить:

```xml
<version>3.4.10</version>
```

на:

```xml
<version>4.0.6</version>
```

и оставить остальное почти как есть, то POM выглядит рискованно.

Минимально я бы точно сделал:

```xml
<camel.version>4.20.0</camel.version>
```

заменил:

```xml
spring-boot-starter-web
```

на:

```xml
spring-boot-starter-webmvc
```

заменил:

```xml
camel-test-spring-junit5
```

на:

```xml
camel-test-spring-junit6
```

заменил:

```xml
logstash-logback-encoder:8.0
```

на:

```xml
logstash-logback-encoder:9.0
```

и убрал бы ручной `kafka-clients:3.9.1`, если только security-политика не требует именно его.

Java 21 обновлять в приложениях не обязательно, но приложения-потребители должны быть готовы к Spring Boot 4. Если они остаются на Boot 3, я бы не подключал к ним новую Boot 4-версию этого стартера.
