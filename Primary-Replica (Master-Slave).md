# Реализация Multi-Master PostgreSQL в Kubernetes с Istio

Архитектура, которую вы описали, называется **Primary-Replica (Master-Slave)** с автоматическим failover. Разберу как это реализовать в Kubernetes с PostgreSQL, используя Patroni для управления репликацией и Istio для маршрутизации трафика.

## Компоненты архитектуры

**Patroni** — управляет PostgreSQL кластером, автоматически выбирает новый Primary при падении текущего, настраивает потоковую репликацию (streaming replication). PostgreSQL имеет встроенный механизм Write-Ahead Log (WAL), который Patroni использует для синхронизации.

**etcd** или **Consul** — распределенное хранилище для координации состояния кластера (какой узел Primary).

**Istio VirtualService** — маршрутизирует запросы на чтение к Replica, на запись к Primary.

**pgBouncer** (опционально) — connection pooler для оптимизации соединений.

## Почему не Debezium в этом случае

Debezium используется для Change Data Capture (CDC) и потоковой передачи изменений в другие системы (Kafka, Elasticsearch). Для репликации внутри PostgreSQL кластера используется **Streaming Replication** — встроенный механизм PostgreSQL, который передает WAL логи от Primary к Replica в реальном времени.

## Пошаговая реализация

### 1. Установка etcd для координации

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: etcd
spec:
  serviceName: etcd
  replicas: 3
  selector:
    matchLabels:
      app: etcd
  template:
    metadata:
      labels:
        app: etcd
    spec:
      containers:
      - name: etcd
        image: quay.io/coreos/etcd:v3.5.9
        ports:
        - containerPort: 2379
          name: client
        - containerPort: 2380
          name: peer
        env:
        - name: ETCD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: ETCD_INITIAL_CLUSTER
          value: "etcd-0=http://etcd-0.etcd:2380,etcd-1=http://etcd-1.etcd:2380,etcd-2=http://etcd-2.etcd:2380"
        - name: ETCD_INITIAL_CLUSTER_STATE
          value: "new"
        - name: ETCD_LISTEN_CLIENT_URLS
          value: "http://0.0.0.0:2379"
        - name: ETCD_ADVERTISE_CLIENT_URLS
          value: "http://$(ETCD_NAME).etcd:2379"
---
apiVersion: v1
kind: Service
metadata:
  name: etcd
spec:
  clusterIP: None
  ports:
  - port: 2379
    name: client
  selector:
    app: etcd
```

### 2. ConfigMap для Patroni

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: patroni-config
data:
  patroni.yml: |
    scope: postgres-cluster
    namespace: /db/
    name: $(POD_NAME)
    
    restapi:
      listen: 0.0.0.0:8008
      connect_address: $(POD_IP):8008
    
    etcd:
      hosts: etcd-0.etcd:2379,etcd-1.etcd:2379,etcd-2.etcd:2379
    
    bootstrap:
      dcs:
        ttl: 30
        loop_wait: 10
        retry_timeout: 10
        maximum_lag_on_failover: 1048576
        postgresql:
          use_pg_rewind: true
          parameters:
            max_connections: 100
            max_wal_senders: 10
            wal_level: replica
            hot_standby: "on"
      
      initdb:
      - encoding: UTF8
      - data-checksums
      
      pg_hba:
      - host replication replicator 0.0.0.0/0 md5
      - host all all 0.0.0.0/0 md5
      
      users:
        admin:
          password: admin_password
          options:
            - createrole
            - createdb
    
    postgresql:
      listen: 0.0.0.0:5432
      connect_address: $(POD_IP):5432
      data_dir: /var/lib/postgresql/data
      pgpass: /tmp/pgpass
      authentication:
        replication:
          username: replicator
          password: replicator_password
        superuser:
          username: postgres
          password: postgres_password
      parameters:
        unix_socket_directories: '/var/run/postgresql'
    
    tags:
      nofailover: false
      noloadbalance: false
      clonefrom: false
```

### 3. StatefulSet для PostgreSQL с Patroni

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
spec:
  serviceName: postgres
  replicas: 3
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
      - name: postgres
        image: postgres:15
        ports:
        - containerPort: 5432
          name: postgresql
        - containerPort: 8008
          name: patroni
        env:
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: POD_IP
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
        - name: PATRONI_CONFIGURATION
          valueFrom:
            configMapKeyRef:
              name: patroni-config
              key: patroni.yml
        volumeMounts:
        - name: postgres-data
          mountPath: /var/lib/postgresql/data
        - name: patroni-config
          mountPath: /etc/patroni
        command:
        - patroni
        - /etc/patroni/patroni.yml
      volumes:
      - name: patroni-config
        configMap:
          name: patroni-config
  volumeClaimTemplates:
  - metadata:
      name: postgres-data
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 10Gi
```

### 4. Services для Primary и Replica

```yaml
# Service для Primary (запись)
apiVersion: v1
kind: Service
metadata:
  name: postgres-primary
  labels:
    app: postgres
    role: primary
spec:
  type: ClusterIP
  ports:
  - port: 5432
    targetPort: 5432
    name: postgresql
  selector:
    app: postgres
    role: master  # Patroni автоматически добавляет этот label
---
# Service для Replica (чтение)
apiVersion: v1
kind: Service
metadata:
  name: postgres-replica
  labels:
    app: postgres
    role: replica
spec:
  type: ClusterIP
  ports:
  - port: 5432
    targetPort: 5432
    name: postgresql
  selector:
    app: postgres
    role: replica  # Patroni автоматически добавляет этот label
---
# Headless service для StatefulSet
apiVersion: v1
kind: Service
metadata:
  name: postgres
spec:
  clusterIP: None
  ports:
  - port: 5432
    name: postgresql
  - port: 8008
    name: patroni
  selector:
    app: postgres
```

### 5. Istio VirtualService для маршрутизации

```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: postgres-routing
spec:
  hosts:
  - postgres-service
  tcp:
  - match:
    - port: 5432
    route:
    - destination:
        host: postgres-primary
        port:
          number: 5432
      weight: 100
---
# Для приложений, делающих только чтение
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: postgres-read-routing
spec:
  hosts:
  - postgres-read-service
  tcp:
  - match:
    - port: 5432
    route:
    - destination:
        host: postgres-replica
        port:
          number: 5432
      weight: 100
---
# Общий service endpoint
apiVersion: v1
kind: Service
metadata:
  name: postgres-service
spec:
  ports:
  - port: 5432
    name: tcp
  selector:
    app: postgres-gateway
---
apiVersion: v1
kind: Service
metadata:
  name: postgres-read-service
spec:
  ports:
  - port: 5432
    name: tcp
  selector:
    app: postgres-gateway
```

### 6. Более продвинутая маршрутизация на уровне приложения

Для более интеллектуальной маршрутизации можно использовать pgBouncer или HAProxy с проверкой типа запроса:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: haproxy-config
data:
  haproxy.cfg: |
    global
      maxconn 100
    
    defaults
      mode tcp
      timeout connect 10s
      timeout client 1m
      timeout server 1m
    
    frontend postgresql_front
      bind *:5432
      default_backend postgresql_back
    
    backend postgresql_back
      option pgsql-check user postgres
      server primary postgres-primary:5432 check
      server replica1 postgres-replica:5432 check backup
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: haproxy
spec:
  replicas: 2
  selector:
    matchLabels:
      app: haproxy
  template:
    metadata:
      labels:
        app: haproxy
    spec:
      containers:
      - name: haproxy
        image: haproxy:2.8
        ports:
        - containerPort: 5432
        volumeMounts:
        - name: config
          mountPath: /usr/local/etc/haproxy
      volumes:
      - name: config
        configMap:
          name: haproxy-config
```

## Как это работает

1. **Нормальная работа**: Patroni определяет один под как Primary (мастер), остальные становятся Replica. Kubernetes Service с селектором `role: master` автоматически направляет трафик на Primary.

2. **Репликация**: Primary отправляет WAL логи через streaming replication на все Replica. Это происходит в реальном времени с минимальной задержкой.

3. **Failover**: Если Primary падает, Patroni автоматически выбирает новый Primary из Replica через консенсус в etcd. Новый Primary получает label `role: master`, Service автоматически переключается.

4. **Восстановление**: Когда старый Primary восстанавливается, Patroni проверяет его состояние, при необходимости использует `pg_rewind` для синхронизации, затем добавляет его как Replica.

5. **Маршрутизация через Istio**: VirtualService направляет запросы на соответствующие endpoints (primary для записи, replica для чтения).

## Мониторинг и проверка состояния

```bash
# Проверить состояние кластера через Patroni API
kubectl exec postgres-0 -- curl http://localhost:8008/cluster

# Подключиться к Primary
kubectl exec -it postgres-0 -- psql -U postgres

# Проверить репликацию
SELECT * FROM pg_stat_replication;

# Проверить является ли узел Primary
SELECT pg_is_in_recovery();
```

Да, вы правильно поняли — в моём примере каждая реплика PostgreSQL размещена в отдельном Pod внутри Kubernetes.

Теперь разберём вариант с **внешними серверами PostgreSQL** (физическими или виртуальными машинами вне Kubernetes).

## Плюсы размещения БД на внешних серверах

1. **Производительность** — выделенное железо с оптимизированными дисками (NVMe, SAS), больше памяти для кэша
2. **Изоляция ресурсов** — БД не конкурирует за CPU/память с другими приложениями в кластере
3. **Упрощённое управление storage** — прямой доступ к дискам без Persistent Volumes
4. **Независимость от Kubernetes** — БД продолжает работать даже при проблемах с кластером
5. **Compliance требования** — некоторые регуляторы требуют физическую изоляцию БД
6. **Проще делать бэкапы** — прямой доступ к файлам данных, snapshots на уровне LVM/ZFS

## Архитектура Primary-Replica на внешних серверах

### Топология

```
Физические серверы:
┌─────────────────────┐
│ pg-master-01        │ Primary (запись)
│ 192.168.1.10        │
└─────────────────────┘
         │
         │ WAL streaming
         ├──────────────┐
         │              │
┌────────▼────────┐ ┌──▼──────────────┐
│ pg-replica-01   │ │ pg-replica-02   │ Replicas (чтение)
│ 192.168.1.11    │ │ 192.168.1.12    │
└─────────────────┘ └─────────────────┘

Kubernetes кластер:
┌─────────────────────────────────────┐
│  Services (ExternalName/Endpoints)  │
│  + Istio VirtualService             │
│  для маршрутизации трафика          │
└─────────────────────────────────────┘
```

## Настройка PostgreSQL на внешних серверах

### 1. Установка PostgreSQL на каждом сервере

```bash
# На всех серверах (Ubuntu/Debian)
apt update
apt install postgresql-15 postgresql-contrib

# Или на RHEL/CentOS
dnf install postgresql15-server postgresql15-contrib
```

### 2. Настройка Primary сервера (192.168.1.10)

**postgresql.conf**:
```ini
# Сетевые настройки
listen_addresses = '*'
port = 5432

# Репликация
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
wal_keep_size = 1GB

# Производительность
shared_buffers = 4GB
effective_cache_size = 12GB
maintenance_work_mem = 1GB
checkpoint_completion_target = 0.9
wal_buffers = 16MB
default_statistics_target = 100
random_page_cost = 1.1
effective_io_concurrency = 200
work_mem = 20MB
min_wal_size = 1GB
max_wal_size = 4GB
max_worker_processes = 4
max_parallel_workers_per_gather = 2
max_parallel_workers = 4

# Hot standby
hot_standby = on
```

**pg_hba.conf**:
```ini
# Локальные подключения
local   all             all                                     peer
host    all             all             127.0.0.1/32            scram-sha-256

# Подключения из Kubernetes (замените на CIDR вашего кластера)
host    all             all             10.0.0.0/8              scram-sha-256

# Репликация с replica серверов
host    replication     replicator      192.168.1.11/32         scram-sha-256
host    replication     replicator      192.168.1.12/32         scram-sha-256
```

**Создание пользователя для репликации**:
```sql
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'strong_password';
```

**Перезапуск**:
```bash
systemctl restart postgresql
```

### 3. Настройка Replica серверов (192.168.1.11, 192.168.1.12)

**Первоначальная синхронизация данных с Primary**:

```bash
# Остановить PostgreSQL на replica
systemctl stop postgresql

# Очистить директорию данных
rm -rf /var/lib/postgresql/15/main/*

# Создать базовый бэкап с Primary
sudo -u postgres pg_basebackup -h 192.168.1.10 -D /var/lib/postgresql/15/main \
  -U replicator -P -v -R -X stream -C -S replica_01_slot

# -R создаст standby.signal и настроит репликацию
# -C создаст replication slot
# -S имя слота репликации (уникально для каждой реплики)
```

**postgresql.conf на replica** (дополнительно к настройкам Primary):
```ini
# Replica специфичные настройки
hot_standby = on
primary_conninfo = 'host=192.168.1.10 port=5432 user=replicator password=strong_password application_name=replica_01'
primary_slot_name = 'replica_01_slot'

# Для cascading replication (опционально)
max_wal_senders = 5
```

**Запуск replica**:
```bash
systemctl start postgresql
```

**Проверка репликации на Primary**:
```sql
SELECT * FROM pg_stat_replication;
-- Должны увидеть подключенные реплики
```

**Проверка на Replica**:
```sql
SELECT pg_is_in_recovery();
-- Вернёт 't' (true) если это replica
```

## Интеграция с Kubernetes через Istio

### 1. Создание Services в Kubernetes для внешних БД

**Вариант A: ExternalName Service** (DNS-based):

```yaml
# Service для Primary
apiVersion: v1
kind: Service
metadata:
  name: postgres-primary-external
spec:
  type: ExternalName
  externalName: pg-master-01.yourdomain.com
  ports:
  - port: 5432
    protocol: TCP
---
# Service для Replica
apiVersion: v1
kind: Service
metadata:
  name: postgres-replica-external
spec:
  type: ExternalName
  externalName: pg-replica.yourdomain.com  # DNS round-robin или L4 балансировщик
  ports:
  - port: 5432
    protocol: TCP
```

**Вариант B: Endpoints (IP-based)** — более гибкий:

```yaml
# Service для Primary
apiVersion: v1
kind: Service
metadata:
  name: postgres-primary
spec:
  ports:
  - port: 5432
    protocol: TCP
    targetPort: 5432
---
apiVersion: v1
kind: Endpoints
metadata:
  name: postgres-primary
subsets:
- addresses:
  - ip: 192.168.1.10
  ports:
  - port: 5432
---
# Service для Replica (с несколькими endpoints)
apiVersion: v1
kind: Service
metadata:
  name: postgres-replica
spec:
  ports:
  - port: 5432
    protocol: TCP
    targetPort: 5432
---
apiVersion: v1
kind: Endpoints
metadata:
  name: postgres-replica
subsets:
- addresses:
  - ip: 192.168.1.11
  - ip: 192.168.1.12
  ports:
  - port: 5432
```

### 2. Istio VirtualService для маршрутизации

```yaml
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: postgres-external
spec:
  hosts:
  - postgres.external.com
  ports:
  - number: 5432
    name: tcp
    protocol: TCP
  location: MESH_EXTERNAL
  resolution: STATIC
  endpoints:
  - address: 192.168.1.10
    labels:
      role: primary
  - address: 192.168.1.11
    labels:
      role: replica
  - address: 192.168.1.12
    labels:
      role: replica
---
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: postgres-routing
spec:
  hosts:
  - postgres.external.com
  tcp:
  - match:
    - port: 5432
      sourceLabels:
        app: write-service  # Приложения, которые делают запись
    route:
    - destination:
        host: postgres.external.com
        subset: primary
  - match:
    - port: 5432
      sourceLabels:
        app: read-service  # Приложения, которые только читают
    route:
    - destination:
        host: postgres.external.com
        subset: replica
---
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: postgres-destination
spec:
  host: postgres.external.com
  subsets:
  - name: primary
    labels:
      role: primary
  - name: replica
    labels:
      role: replica
    trafficPolicy:
      loadBalancer:
        simple: ROUND_ROBIN
```

### 3. Более простая маршрутизация через HAProxy/pgBouncer

Если Istio избыточен, можно развернуть HAProxy в Kubernetes как точку входа:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: haproxy-config
data:
  haproxy.cfg: |
    global
      maxconn 1000
      log stdout format raw local0
    
    defaults
      mode tcp
      log global
      option tcplog
      timeout connect 10s
      timeout client 30m
      timeout server 30m
    
    # Frontend для приложений
    frontend pg_write
      bind *:5432
      default_backend pg_primary
    
    frontend pg_read
      bind *:5433
      default_backend pg_replicas
    
    # Backends
    backend pg_primary
      option pgsql-check user postgres
      server primary 192.168.1.10:5432 check inter 5s fall 3 rise 2
    
    backend pg_replicas
      balance roundrobin
      option pgsql-check user postgres
      server replica1 192.168.1.11:5432 check inter 5s fall 3 rise 2
      server replica2 192.168.1.12:5432 check inter 5s fall 3 rise 2
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: haproxy
spec:
  replicas: 2
  selector:
    matchLabels:
      app: haproxy
  template:
    metadata:
      labels:
        app: haproxy
    spec:
      containers:
      - name: haproxy
        image: haproxy:2.8-alpine
        ports:
        - containerPort: 5432
          name: write
        - containerPort: 5433
          name: read
        volumeMounts:
        - name: config
          mountPath: /usr/local/etc/haproxy
      volumes:
      - name: config
        configMap:
          name: haproxy-config
---
apiVersion: v1
kind: Service
metadata:
  name: postgres-proxy
spec:
  type: ClusterIP
  ports:
  - port: 5432
    targetPort: 5432
    name: write
  - port: 5433
    targetPort: 5433
    name: read
  selector:
    app: haproxy
```

## Автоматический Failover на внешних серверах

Для автоматического переключения Primary при падении используем **Patroni** на внешних серверах с etcd или Consul.

### 1. Установка etcd на отдельных серверах или в Kubernetes

```bash
# На отдельном сервере
wget https://github.com/etcd-io/etcd/releases/download/v3.5.9/etcd-v3.5.9-linux-amd64.tar.gz
tar xzvf etcd-v3.5.9-linux-amd64.tar.gz
cd etcd-v3.5.9-linux-amd64
./etcd --listen-client-urls http://0.0.0.0:2379 \
       --advertise-client-urls http://192.168.1.20:2379
```

### 2. Установка Patroni на каждом PostgreSQL сервере

```bash
pip3 install patroni[etcd] psycopg2-binary
```

### 3. Конфигурация Patroni

**/etc/patroni.yml** на каждом сервере:

**Primary (192.168.1.10)**:
```yaml
scope: postgres-cluster
namespace: /db/
name: pg-node-01

restapi:
  listen: 0.0.0.0:8008
  connect_address: 192.168.1.10:8008

etcd:
  hosts: 192.168.1.20:2379

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: true
      parameters:
        max_connections: 200
        max_wal_senders: 10
        wal_level: replica
        hot_standby: "on"
  
  initdb:
  - encoding: UTF8
  - data-checksums
  
  pg_hba:
  - host replication replicator 192.168.1.0/24 scram-sha-256
  - host all all 0.0.0.0/0 scram-sha-256
  
  users:
    admin:
      password: admin_pass
      options:
        - createrole
        - createdb

postgresql:
  listen: 0.0.0.0:5432
  connect_address: 192.168.1.10:5432
  data_dir: /var/lib/postgresql/15/main
  bin_dir: /usr/lib/postgresql/15/bin
  authentication:
    replication:
      username: replicator
      password: replicator_pass
    superuser:
      username: postgres
      password: postgres_pass

tags:
  nofailover: false
  noloadbalance: false
```

**Replica (192.168.1.11)** — аналогично, меняем:
```yaml
name: pg-node-02
connect_address: 192.168.1.11:8008
postgresql:
  connect_address: 192.168.1.11:5432
```

### 4. Запуск Patroni как systemd service

**/etc/systemd/system/patroni.service**:
```ini
[Unit]
Description=Patroni PostgreSQL High-Availability Manager
After=network.target

[Service]
Type=simple
User=postgres
Group=postgres
ExecStart=/usr/local/bin/patroni /etc/patroni.yml
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
TimeoutSec=30
Restart=always

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload
systemctl enable patroni
systemctl start patroni
```

### 5. Проверка состояния кластера

```bash
# На любом сервере с Patroni
patronictl -c /etc/patroni.yml list

# Вывод:
# + Cluster: postgres-cluster ---+---------+---------+----+-----------+
# | Member     | Host          | Role    | State   | TL | Lag in MB |
# +------------+---------------+---------+---------+----+-----------+
# | pg-node-01 | 192.168.1.10  | Leader  | running |  2 |           |
# | pg-node-02 | 192.168.1.11  | Replica | running |  2 |         0 |
# | pg-node-03 | 192.168.1.12  | Replica | running |  2 |         0 |
# +------------+---------------+---------+---------+----+-----------+
```

## Добавление нового сервера в кластер

### Шаг 1: Подготовить новый сервер
```bash
# Установить PostgreSQL
apt install postgresql-15

# Установить Patroni
pip3 install patroni[etcd] psycopg2-binary
```

### Шаг 2: Создать конфигурацию Patroni
```yaml
# /etc/patroni.yml на новом сервере (192.168.1.13)
scope: postgres-cluster
namespace: /db/
name: pg-node-04

restapi:
  listen: 0.0.0.0:8008
  connect_address: 192.168.1.13:8008

etcd:
  hosts: 192.168.1.20:2379

postgresql:
  listen: 0.0.0.0:5432
  connect_address: 192.168.1.13:5432
  data_dir: /var/lib/postgresql/15/main
  bin_dir: /usr/lib/postgresql/15/bin
  authentication:
    replication:
      username: replicator
      password: replicator_pass
    superuser:
      username: postgres
      password: postgres_pass
```

### Шаг 3: Запустить Patroni
```bash
systemctl start patroni
```

Patroni автоматически:
- Подключится к etcd
- Найдёт текущий Primary
- Выполнит `pg_basebackup` для начальной синхронизации
- Начнёт streaming replication
- Зарегистрируется как новая Replica

### Шаг 4: Обновить Kubernetes Endpoints
```yaml
apiVersion: v1
kind: Endpoints
metadata:
  name: postgres-replica
subsets:
- addresses:
  - ip: 192.168.1.11
  - ip: 192.168.1.12
  - ip: 192.168.1.13  # Новый сервер
  ports:
  - port: 5432
```

```bash
kubectl apply -f endpoints.yaml
```

## Удаление сервера из кластера

### Шаг 1: Остановить Patroni
```bash
systemctl stop patroni
```

### Шаг 2: Удалить узел из etcd
```bash
patronictl -c /etc/patroni.yml remove pg-node-04
```

### Шаг 3: Обновить Endpoints в Kubernetes
```bash
kubectl edit endpoints postgres-replica
# Удалить IP адрес сервера
```

## Мониторинг внешних серверов из Kubernetes

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-postgres-exporter
data:
  queries.yaml: |
    pg_replication:
      query: "SELECT EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp())) as lag"
      metrics:
        - lag:
            usage: "GAUGE"
            description: "Replication lag behind master in seconds"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres-exporter
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres-exporter
  template:
    metadata:
      labels:
        app: postgres-exporter
    spec:
      containers:
      - name: exporter
        image: prometheuscommunity/postgres-exporter
        env:
        - name: DATA_SOURCE_NAME
          value: "postgresql://postgres:password@192.168.1.10:5432/postgres?sslmode=disable"
        ports:
        - containerPort: 9187
```

Такая архитектура даёт лучший контроль над железом и производительностью, сохраняя гибкость интеграции с Kubernetes через Service Mesh.

Эта архитектура обеспечивает высокую доступность, автоматический failover и распределение нагрузки на чтение между репликами.
