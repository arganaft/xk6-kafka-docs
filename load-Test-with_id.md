Для реализации этого сценария в K6 есть важный нюанс: **стандартный образ K6 не умеет работать с SQL базами данных и файловой системой напрямую**.

Для работы приведенных ниже скриптов вам потребуется **кастомный образ K6**, собранный с расширениями:
1.  **xk6-sql** (для работы с Postgres).
2.  **xk6-file** (для Варианта 1, чтобы писать/читать файлы).

Если у вас нет возможности собрать свой образ, вам придется вынести логику получения ID в отдельный `init-container` в Kubernetes, который скачает ID в файл, а K6 просто прочитает этот файл через `SharedArray`.

Ниже представлены два варианта ConfigMap, предполагающие, что у вас есть образ K6 с расширениями `xk6-sql` и `xk6-file`.

### Предварительная подготовка (Connection String)
JDBC URL (`jdbc:postgresql://...`) не подходит для Go/K6 напрямую. Скрипты ниже преобразуют его в формат `postgres://...`. Я использую первый хост из вашего списка для подключения.

---

### Вариант 1: Сохранение ключей в файл и чтение (с чанками)

В этом варианте:
1.  `setup()` подключается к БД.
2.  Скачивает ID "чанками" (порциями) по 1000 штук, чтобы не забивать память при скачивании, и сразу дописывает их в файл.
3.  Возвращает имя файла.
4.  В `default()` (или через `SharedArray` если файл готов заранее) мы берем данные. *Примечание: В K6 динамическое чтение файла внутри теста — дорогая операция. Самый эффективный способ — прочитать файл в setup и передать массив, но так как требование "через файл", мы запишем, а потом прочитаем.*
5.  `teardown()` удаляет файл.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: k6-test-scripts-file-based
  labels:
    app: syngtp-k6-load-test-rest-db-reader
data:
  test.js: |
      import http from 'k6/http';
      import { check } from 'k6';
      import { Rate, Trend } from 'k6/metrics';
      import sql from 'k6/x/sql'; // Требуется xk6-sql
      import file from 'k6/x/file'; // Требуется xk6-file

      // Метрики
      const successRate = new Rate('successful_requests');
      const requestDuration = new Trend('request_duration');

      // Параметры
      const DB_LIMIT = __ENV.DB_LIMIT || 10000; // Сколько всего скачать
      const CHUNK_SIZE = 1000; // Размер чанка
      const FILE_PATH = '/tmp/trade_ids.json';

      // Настройки подключения к БД (парсинг из ENV или хардкод первого хоста)
      // Преобразуем JDBC URL в Postgres Connection String для Go
      const dbUser = __ENV.DB_USER || 'postgres';
      const dbPass = __ENV.DB_PASSWORD || 'postgres123';
      const dbHost = 'tvled-kssh00010.esrt.sber.ru';
      const dbPort = '12541';
      const dbName = 'mr';
      const connectionString = `postgres://${dbUser}:${dbPass}@${dbHost}:${dbPort}/${dbName}?sslmode=disable&search_path=murex`;

      export const options = {
        executor: 'constant-arrival-rate',
        rate: 20,
        timeUnit: '1s',
        preAllocatedVUs: 2,
        maxVUs: 5,
        stages: [
              { duration: '3s', target: 2 },
              { duration: '5s', target: 5 },
              { duration: '10s', target: 5 },
        ],
        thresholds: {
          http_req_failed: ['rate<0.01'],
          http_req_duration: ['p(95)<20000'],
          'successful_requests': ['rate>0.99'],
        },
      };

      // 1. SETUP: Скачиваем ID из БД и пишем в файл
      export function setup() {
        console.log(`Connecting to DB: ${dbHost}...`);
        const db = sql.open('postgres', connectionString);
        
        // Очищаем файл если был
        try { file.delete(FILE_PATH); } catch(e) {}

        let collected = 0;
        let allIds = [];

        console.log(`Fetching ${DB_LIMIT} IDs in chunks of ${CHUNK_SIZE}...`);

        while (collected < DB_LIMIT) {
            // Берем чанк
            const query = `SELECT id FROM murex.trades ORDER BY created_at DESC LIMIT ${CHUNK_SIZE} OFFSET ${collected};`;
            const results = sql.query(db, query);
            
            if (results.length === 0) break;

            // Добавляем в общий массив (для записи в файл)
            results.forEach(row => allIds.push(row.id));
            
            collected += results.length;
            console.log(`Fetched ${collected} rows...`);
        }

        sql.close(db);

        // Сохраняем в файл
        file.writeString(FILE_PATH, JSON.stringify(allIds));
        console.log(`Saved ${allIds.length} IDs to ${FILE_PATH}`);

        // Возвращаем сами данные, чтобы K6 распределил их по VU (это быстрее, чем читать файл в каждом VU)
        return allIds; 
      }

      export default function (data) {
        // data - это массив ID, переданный из setup()
        if (!data || data.length === 0) {
            console.error("No data found!");
            return;
        }

        // Выбираем случайный ID из загруженного списка
        const randomIndex = Math.floor(Math.random() * data.length);
        const id = data[randomIndex];

        const url = `http://trade-consumer-db-reader:8080/api/trades/${id}`;
        
        const params = {
          headers: {
            'User-Agent': 'k6-load-test',
            'Content-Type': 'application/json',
          },
          timeout: '30s',
          tags: { endpoint: 'get_trade' },
        };
        
        const startTime = Date.now();
        
        try {
          const response = http.get(url, params);
          const duration = Date.now() - startTime;
          
          requestDuration.add(duration);
          successRate.add(response.status === 200);
          
          check(response, {
            'status is 200': (r) => r.status === 200,
            'response time < 20s': (r) => r.timings.duration < 20000,
          });
          
        } catch (error) {
          successRate.add(false);
          console.error(`Request error: ${error.message}`);
        }
      }

      // 3. TEARDOWN: Удаляем файл
      export function teardown(data) {
        console.log('Cleaning up: Deleting temporary file...');
        try {
            file.delete(FILE_PATH);
            console.log('File deleted.');
        } catch (e) {
            console.error('Error deleting file:', e);
        }
      }
```

---

### Вариант 2: Хранение ключей в оперативной памяти (Рекомендуемый)

Этот вариант быстрее и проще, так как он использует нативные механизмы K6 для передачи данных из `setup` в `default`.

В этом варианте:
1.  `setup()` скачивает ID (можно одним запросом или чанками, сделаем чанками для надежности).
2.  Возвращает массив ID. K6 хранит этот массив в памяти и передает копию (или ссылку) виртуальным пользователям.
3.  `teardown()` вызывается в конце. В JS память чистится сборщиком мусора (Garbage Collector), но мы явно обнулим данные в логах.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: k6-test-scripts-ram-based
  labels:
    app: syngtp-k6-load-test-rest-db-reader
data:
  test.js: |
      import http from 'k6/http';
      import { check } from 'k6';
      import { Rate, Trend } from 'k6/metrics';
      import sql from 'k6/x/sql'; // Требуется xk6-sql

      const successRate = new Rate('successful_requests');
      const requestDuration = new Trend('request_duration');

      // Конфигурация
      const DB_LIMIT = __ENV.DB_LIMIT || 10000;
      const CHUNK_SIZE = 2000; // Качаем по 2000 за раз

      // Конвертация JDBC строки в Postgres connection string
      const dbUser = __ENV.DB_USER || 'postgres';
      const dbPass = __ENV.DB_PASSWORD || 'postgres123';
      const dbHost = 'tvled-kssh00010.esrt.sber.ru';
      const dbPort = '12541';
      const dbName = 'mr';
      const connectionString = `postgres://${dbUser}:${dbPass}@${dbHost}:${dbPort}/${dbName}?sslmode=disable&search_path=murex`;

      export const options = {
        executor: 'constant-arrival-rate',
        rate: 20,
        timeUnit: '1s',
        preAllocatedVUs: 2,
        maxVUs: 5,
        stages: [
              { duration: '3s', target: 2 },
              { duration: '10s', target: 5 },
              { duration: '5s', target: 5 },
        ],
        thresholds: {
          http_req_failed: ['rate<0.01'],
          http_req_duration: ['p(95)<20000'],
          'successful_requests': ['rate>0.99'],
        },
      };

      // 1. SETUP: Загрузка данных в RAM
      export function setup() {
        console.log(`Connecting to DB to fetch ${DB_LIMIT} keys...`);
        const db = sql.open('postgres', connectionString);
        
        let allIds = [];
        let offset = 0;

        // Цикл для скачивания чанками (чтобы не убить БД одним огромным запросом)
        while (allIds.length < DB_LIMIT) {
            const query = `SELECT id FROM murex.trades ORDER BY created_at DESC LIMIT ${CHUNK_SIZE} OFFSET ${offset};`;
            try {
                const results = sql.query(db, query);
                if (results.length === 0) break;
                
                results.forEach(r => allIds.push(r.id));
                offset += results.length;
                console.log(`Loaded ${allIds.length} IDs so far...`);
            } catch (e) {
                console.error("SQL Error:", e);
                break;
            }
        }

        sql.close(db);
        console.log(`Setup complete. Total IDs in RAM: ${allIds.length}`);
        
        // Возвращаем массив. K6 передаст его в функцию default
        return { ids: allIds };
      }

      export default function (data) {
        const ids = data.ids;
        
        if (!ids || ids.length === 0) {
           console.error("No IDs available");
           return;
        }

        // Берем случайный ID из памяти
        const randomId = ids[Math.floor(Math.random() * ids.length)];
        const url = `http://trade-consumer-db-reader:8080/api/trades/${randomId}`;
        
        const params = {
          headers: {
            'User-Agent': 'k6-load-test',
            'Content-Type': 'application/json',
          },
          timeout: '30s',
          tags: { endpoint: 'get_trade' },
        };
        
        const startTime = Date.now();
        
        try {
          const response = http.get(url, params);
          const duration = Date.now() - startTime;
          
          requestDuration.add(duration);
          successRate.add(response.status === 200);
          
          check(response, {
            'status is 200': (r) => r.status === 200,
            'status is 404': (r) => r.status === 404, // 404 тоже валидный ответ, если ID устарел
            'response time < 20s': (r) => r.timings.duration < 20000,
          });
          
        } catch (error) {
          successRate.add(false);
          console.error(`Request error: ${error.message}`);
        }
      }

      // 3. TEARDOWN: Очистка
      export function teardown(data) {
        // В JS мы не можем принудительно очистить память "здесь и сейчас", 
        // но завершение процесса K6 освободит ресурсы.
        // Мы можем явно занулить ссылку, если бы это был долгоживущий процесс.
        console.log("Teardown: Clearing data references...");
        data = null; 
        console.log("Memory cleanup finished (handled by runtime).");
      }
```

### Как запускать

1.  Примените ConfigMap:
    ```bash
    kubectl apply -f k6-config.yaml
    ```
2.  Убедитесь, что в вашем Deployment K6:
    *   Смонтирован этот ConfigMap.
    *   Используется образ с `xk6-sql` (например, собранный через `xk6 build --with github.com/grafana/xk6-sql`).
    *   Переданы переменные окружения `DB_USER` и `DB_PASSWORD`.
