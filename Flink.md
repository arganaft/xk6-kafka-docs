Для запуска Apache Flink в Kubernetes для целей тестирования и бенчмарков, когда вам не нужна отказоустойчивость и сохранение состояния (через чекпоинты), конфигурация получается достаточно легкой.

Вам понадобятся три основных компонента:
1.  **ConfigMap**: настройки `flink-conf.yaml`.
2.  **JobManager**: "голова" кластера (Deployment + Service).
3.  **TaskManager**: рабочие узлы (Deployment).

Вот примеры манифестов, которые можно объединить в один файл или разложить по разным.

---

### 1. ConfigMap
Здесь мы прописываем адрес JobManager, чтобы воркеры знали, куда подключаться, и отключаем все, что связано с диском.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: flink-config
  labels:
    app: flink
data:
  flink-conf.yaml: |+
    jobmanager.rpc.address: flink-jobmanager
    taskmanager.numberOfTaskSlots: 2
    blob.server.port: 6124
    jobmanager.rpc.port: 6123
    taskmanager.rpc.port: 6122
    queryserver.port: 6125
    # Настройки памяти (подберите под свои нужды)
    jobmanager.memory.process.size: 1600m
    taskmanager.memory.process.size: 2048m
    parallelism.default: 2
    # Отключаем чекпоинты на уровне конфигурации (опционально, обычно задается в коде)
    execution.checkpointing.interval: 0
  log4j-console.properties: |+
    rootLogger.level = INFO
    rootLogger.appenderRef.console.ref = ConsoleAppender
    appender.console.name = ConsoleAppender
    appender.console.type = Console
    appender.console.layout.type = PatternLayout
    appender.console.layout.pattern = %d{yyyy-MM-dd HH:mm:ss,SSS} %-5p %-60c %x - %m%n
```

---

### 2. JobManager (Deployment + Service)
Сервис нужен, чтобы TaskManager'ы могли найти JobManager по DNS-имени `flink-jobmanager`.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: flink-jobmanager
spec:
  type: ClusterIP # Используйте NodePort или LoadBalancer, если нужен доступ к UI снаружи
  ports:
  - name: rpc
    port: 6123
  - name: blob-server
    port: 6124
  - name: webui
    port: 8081
  selector:
    app: flink
    component: jobmanager
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: flink-jobmanager
spec:
  replicas: 1
  selector:
    matchLabels:
      app: flink
      component: jobmanager
  template:
    metadata:
      labels:
        app: flink
        component: jobmanager
    spec:
      containers:
      - name: jobmanager
        image: <ВАШ_ОБРАЗ> # Замените на ваш тег
        args: ["jobmanager"]
        ports:
        - containerPort: 6123
          name: rpc
        - containerPort: 6124
          name: blob-server
        - containerPort: 8081
          name: webui
        volumeMounts:
        - name: flink-config-volume
          mountPath: /opt/flink/conf
        securityContext:
          runAsUser: 9999 # Зависит от вашего Docker-образа
      volumes:
      - name: flink-config-volume
        configMap:
          name: flink-config
          items:
          - key: flink-conf.yaml
            path: flink-conf.yaml
          - key: log4j-console.properties
            path: log4j-console.properties
```

---

### 3. TaskManager (Deployment)
Здесь мы указываем количество "воркеров". Поскольку это тест, можно поставить `replicas: 1` или больше.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: flink-taskmanager
spec:
  replicas: 2 # Количество воркеров
  selector:
    matchLabels:
      app: flink
      component: taskmanager
  template:
    metadata:
      labels:
        app: flink
        component: taskmanager
    spec:
      containers:
      - name: taskmanager
        image: <ВАШ_ОБРАЗ> # Замените на ваш тег
        args: ["taskmanager"]
        ports:
        - containerPort: 6122
          name: rpc
        - containerPort: 6125
          name: query-server
        volumeMounts:
        - name: flink-config-volume
          mountPath: /opt/flink/conf
        securityContext:
          runAsUser: 9999
      volumes:
      - name: flink-config-volume
        configMap:
          name: flink-config
          items:
          - key: flink-conf.yaml
            path: flink-conf.yaml
          - key: log4j-console.properties
            path: log4j-console.properties
```

---

### Важные нюансы для вашего случая:

* **Работа в памяти**: В данной конфигурации мы не подключаем `PersistentVolumeClaim`. Это значит, что если Pod упадет, все данные из RocksDB (если вы её используете) или внутреннего состояния пропадут. Для тестов и бенчмарков это именно то, что вы просили.
* **Бенчмарки**: Если вы планируете замерять производительность, обязательно пропишите `resources` (limits и requests) в Deployment для обоих компонентов. K8s может начать "душить" Flink по CPU (Throttling), и ваши бенчмарки будут некорректными.
* **Порт 8081**: Чтобы посмотреть UI Flink с локальной машины, используйте команду:
    `kubectl port-forward service/flink-jobmanager 8081:8081`
* **EntryPoint**: Убедитесь, что в вашем Docker-образе прописан скрипт `docker-entrypoint.sh`. Стандартные образы Flink его имеют, и команды `jobmanager` / `taskmanager` запустят нужные процессы автоматически.

Нужно ли вам помочь с настройкой `resources` для CPU/RAM под конкретные лимиты вашего железа?


### при запуске docker файла в POD появляется такая ошибка:
/opt/flink/bin/config-parser-utils.sh: line 42: /opt/flink/conf/config.yaml: Read-only file system
/opt/flink/bin/config-parser-utils.sh: line 42: /opt/flink/conf/config.yaml: Read-only file system
Usage: docker-entrypoint.sh (jobmanager|standalone-job|taskmanager|history-server)
    Or docker-entrypoint.sh help
By default, Flink image adopts jemalloc as default memory allocator. This behavior can be disabled by setting the 'DISABLE_JEMALLOC' environment variable to 'true'.
я в файлах Kubernetes я удалил все ссылки на /opt/flink/bin но он почему то опять пытается туда записывать, возможно причина в том что  docker-entrypoint.sh прописан этот путь, можно ли его переопределить? 

# Это классическая проблема при запуске Flink в Kubernetes. Ошибка возникает из-за того, что когда вы монтируете `ConfigMap` прямо в директорию `/opt/flink/conf`, Kubernetes делает всю эту директорию (или файлы в ней) **read-only**.

Скрипт `docker-entrypoint.sh` (и вызываемый им парсер конфигурации) при запуске пытается динамически изменять или создавать файлы в папке `conf` (например, для настройки памяти или записи обработанного `config.yaml`). Так как файловая система только для чтения, он "падает".

Вот три способа решить эту проблему, от самого правильного до самого простого:

---

### Решение 1: Использование InitContainer и emptyDir (Самое надежное)
Это стандартный путь для Flink. Мы создаем пустую временную папку (`emptyDir`), которая разрешает запись, и перед запуском основного контейнера копируем туда конфиги из ConfigMap.

Вставьте это в `spec` вашего **Deployment** (и для JobManager, и для TaskManager):

```yaml
spec:
  template:
    spec:
      # 1. Создаем общее хранилище в памяти для конфигов
      volumes:
        - name: flink-config-writable
          emptyDir: {}
        - name: flink-config-readonly
          configMap:
            name: flink-config

      # 2. Копируем файлы из Read-Only в Writable перед стартом
      initContainers:
      - name: copy-configs
        image: busybox
        command: ['sh', '-c', 'cp /config-readonly/* /config-writable/']
        volumeMounts:
        - name: flink-config-readonly
          mountPath: /config-readonly
        - name: flink-config-writable
          mountPath: /config-writable

      containers:
      - name: jobmanager # или taskmanager
        image: <ВАШ_ОБРАЗ>
        # ... остальные настройки ...
        volumeMounts:
        - name: flink-config-writable
          mountPath: /opt/flink/conf # Теперь это папка с правами на запись
```

---

### Решение 2: Использование subPath (Самое быстрое)
Если вы монтируете файл через `subPath`, Kubernetes монтирует только конкретный файл, а не всю директорию. Сама директория `/opt/flink/conf` остается частью образа и доступна для записи.

**Но будьте осторожны:** если Flink захочет изменить именно файл `config.yaml`, он все равно выдаст ошибку. Однако часто ему нужно просто создать соседние файлы.

```yaml
        volumeMounts:
        - name: flink-config-volume
          mountPath: /opt/flink/conf/config.yaml # или flink-conf.yaml
          subPath: config.yaml
```

*Примечание: В Flink 1.18+ файл конфигурации называется `config.yaml`, в более старых — `flink-conf.yaml`. Судя по вашей ошибке, у вас новая версия.*

---

### Решение 3: Передача настроек через Environment Variables
Если настроек немного, вы можете вообще не монтировать ConfigMap как файл, а использовать переменную окружения `FLINK_PROPERTIES`. Скрипт `docker-entrypoint.sh` умеет подхватывать её и генерировать конфиг самостоятельно.

```yaml
      containers:
      - name: jobmanager
        env:
        - name: FLINK_PROPERTIES
          value: |
            jobmanager.rpc.address: flink-jobmanager
            taskmanager.numberOfTaskSlots: 2
            jobmanager.memory.process.size: 1600m
```
В этом случае вам вообще не нужно трогать `/opt/flink/conf`, и ошибок записи не будет.

---

### Почему ваше удаление ссылок на `/opt/flink/bin` не помогло?
Скрипты в `bin` — это "мозг" запуска Flink внутри контейнера. Даже если вы не вызываете их в YAML, их вызывает `docker-entrypoint.sh` (точка входа в Docker-образ). Переопределить их можно, изменив `command` или `args` в Kubernetes, но лучше не ломать логику старта, а просто дать Flink **права на запись** в его родную папку конфигов (как показано в Решении 1).

Какую версию Flink вы используете? В версии 1.18 произошел переход на новый формат YAML, и если ваш `ConfigMap` написан в старом стиле, а образ новый — это тоже может вызвать проблемы с парсингом.
