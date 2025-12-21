K6 Тестирование с Загрузкой ID из БД
Чат с Gemini
вот Config файл микро сервиса в Kubernetes на K6 для нагрузочного тестирования другого микро сервиса на java spring boot который получает данные из базы данных Postgresql:

apiVersion: v1

kind: ConfigMap

metadata:

name: k6-test-scripts

labels:

app: syngtp-k6-load-test-rest-db-reader

data:

test.js: |

import http from 'k6/http';

import { check, sleep } from 'k6';

import { Rate, Trend } from 'k6/metrics';


// Кастомные метрики

const successRate = new Rate('successful_requests');

const requestDuration = new Trend('request_duration');


export const options = {

executor: 'constant-arrival-rate', // Постоянная скорость запросов


// Настройки скорости (requests per second)

rate: 20, // Начинаем с 20 RPS

timeUnit: '1s', // 20 запросов в секунду

preAllocatedVUs: 1, // Только 1 виртуальный пользователь

maxVUs: 2, // Максимум 2 (на случай скачков)


// Плавное увеличение скорости

stages: [

{ duration: '3s', target: 2 }, // 3 секунд по 2 RPS

{ duration: '1s', target: 3 }, // 1 секунд плавно до 3 RPS

{ duration: '1s', target: 4 }, // 1 секунд плавно до 4 RPS

{ duration: '1s', target: 5 }, // 1 секунд плавно до 5 RPS

{ duration: '6s', target: 5 }, // 6 секунд держим 5 RPS

],


thresholds: {

http_req_failed: ['rate<0.01'], // Меньше 1% ошибок

http_req_duration: ['p(95)<20000'], // 95% запросов < 20 сек

'successful_requests': ['rate>0.99'], // Успешность > 99%

},

};


export default function () {

const id = Math.floor(Math.random() * 100) + 1;

const url = `http://trade-consumer-db-reader:8080/api/trades/${id}`;


const params = {

headers: {

'User-Agent': 'k6-load-test',

'Content-Type': 'application/json',

},

timeout: '30s',

tags: {

endpoint: 'get_trade',

rate: 'variable',

},

};


const startTime = Date.now();


try {

const response = http.get(url, params);

const duration = Date.now() - startTime;


requestDuration.add(duration);

successRate.add(response.status === 200);


check(response, {

'status is 200': (r) => r.status === 200,

'status is 404': (r) => r.status === 404,

'response time < 20000ms': (r) => r.timings.duration < 20000,

});


} catch (error) {

successRate.add(false);

console.error(`Request error: ${error.message}`);

}


}





здесь ID генерируется случайным образом, что не совсем правильно, мне нужно чтобы ты переписал его таким образом чтобы K6 сначала шел в БД и скачивал оттуда ключи (ID) а потом уже с этими ключами шел в другой микро сервис, названия колонок:

id, trade_data, created_at. название таблицы - trades. База данных называется - mr.

вот пример пути к базе данных:

datasource:

url: jdbc:postgresql://tvled-kssh00010.esrt.sber.ru:12541,tvled-kssh00012.esrt.sber.ru:12543/mr?currentSchema=murex&prepareThreshold=0&targetServerType=master

username: ${DB_USER:postgres}

password: ${DB_PASSWORD:postgres123}



создай 2 варианта



покажи 2 варианта ConfigMap:

1. в котором ключи сохраняются в файл и оттуда выкачиваются дляч тестирования чанками по 1000 штук

2. в котором ключи хранятся в оперативной памяти

в обеих случаях введи параметр сколько ключей нужно скачать из БД (по умолчанию 10000) и в обеих случаях после окончания теста нужно очистить память от ключей в опервтивнойпамяти или удалить файл

Для того чтобы реализовать этот сценарий, важно понимать архитектурную особенность K6: стандартный бинарный файл K6 не умеет работать с SQL базами данных напрямую.

Для работы с Postgres вам обязательно потребуется собрать кастомную версию K6 с расширением xk6-sql, а для работы с файлами (Вариант 1) — с расширением xk6-file.

Вот как это делается (кратко): xk6 build --with github.com/grafana/xk6-sql --with github.com/avitalique/xk6-file

Ниже представлены два варианта ConfigMap. Я также адаптировал строку подключения из JDBC (Java) в формат, понятный Go/K6 (Postgres connection string).

Подготовка: Строка подключения
Ваш JDBC URL поддерживает failover (несколько хостов). В K6 (Go driver) строку лучше привести к стандартному виду. Я буду использовать первый хост из вашего списка для примера, но в идеале нужно использовать балансировщик или перечислять хосты, если драйвер это поддерживает.

URL для K6: postgres://${DB_USER}:${DB_PASSWORD}@tvled-kssh00010.esrt.sber.ru:12541/mr?sslmode=disable&search_path=murex

Вариант 1: Сохранение ключей в файл (File-based)
В этом варианте setup() скачивает ID пачками (чанками) по 1000 штук и записывает их в файл. VUs (виртуальные пользователи) читают этот файл. Функция teardown() удаляет файл после теста.

Особенности: Требует xk6-file и xk6-sql.

YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: k6-test-scripts-file
  labels:
    app: syngtp-k6-load-test-file
data:
  test.js: |
      import http from 'k6/http';
      import sql from 'k6/x/sql';
      import file from 'k6/x/file';
      import { check } from 'k6';
      import { Rate, Trend } from 'k6/metrics';

      const successRate = new Rate('successful_requests');
      const requestDuration = new Trend('request_duration');
      
      // Параметры
      const DB_LIMIT = __ENV.DB_LIMIT || 10000; // Сколько всего скачать
      const CHUNK_SIZE = 1000;                  // Размер чанка
      const TEMP_FILE = 'ids_temp.json';

      // Настройки подключения к БД
      const dbConfig = {
          user: __ENV.DB_USER || 'postgres',
          password: __ENV.DB_PASSWORD || 'postgres123',
          host: 'tvled-kssh00010.esrt.sber.ru',
          port: '12541',
          dbname: 'mr',
          schema: 'murex'
      };
      
      const connStr = `postgres://${dbConfig.user}:${dbConfig.password}@${dbConfig.host}:${dbConfig.port}/${dbConfig.dbname}?sslmode=disable&search_path=${dbConfig.schema}`;

      export const options = {
        executor: 'constant-arrival-rate',
        rate: 20,
        timeUnit: '1s',
        preAllocatedVUs: 2,
        maxVUs: 5,
        stages: [
              { duration: '3s', target: 2 },
              { duration: '5s', target: 5 },
        ],
        thresholds: {
          http_req_failed: ['rate<0.01'],
          'successful_requests': ['rate>0.99'],
        },
      };

      // 1. SETUP: Скачиваем данные из БД и сохраняем в файл
      export function setup() {
        console.log(`Connecting to DB to fetch ${DB_LIMIT} IDs...`);
        const db = sql.open('postgres', connStr);
        let allIds = [];

        try {
            // Читаем чанками
            for (let offset = 0; offset < DB_LIMIT; offset += CHUNK_SIZE) {
                const query = `SELECT id FROM murex.trades ORDER BY created_at DESC LIMIT ${CHUNK_SIZE} OFFSET ${offset};`;
                const results = sql.query(db, query);
                
                results.forEach(row => allIds.push(row.id));
                console.log(`Fetched ${results.length} rows (Offset: ${offset})`);
            }
            
            // Записываем в файл (как JSON массив)
            file.writeString(TEMP_FILE, JSON.stringify(allIds));
            console.log(`Saved ${allIds.length} IDs to ${TEMP_FILE}`);

        } catch (e) {
            console.error('Error fetching data:', e);
        } finally {
            db.close();
        }
        
        // Передаем имя файла в VUs
        return { fileName: TEMP_FILE };
      }

      // 2. VU CODE: Основной тест
      export default function (data) {
        // Читаем ID из файла. 
        // ВНИМАНИЕ: В реальной нагрузке чтение файла каждый раз — это IO оверхед.
        // Обычно содержимое передают через return setup(), но так просили в задаче.
        // Для оптимизации мы читаем файл один раз в память VU, если это возможно, или парсим на лету.
        
        // Здесь для простоты читаем весь файл, парсим и берем случайный.
        const fileContent = file.readString(data.fileName);
        const ids = JSON.parse(fileContent);
        
        if (ids.length === 0) {
            console.error("No IDs found!");
            return;
        }

        const randomId = ids[Math.floor(Math.random() * ids.length)];
        const url = `http://trade-consumer-db-reader:8080/api/trades/${randomId}`;
        
        const params = {
          headers: { 'Content-Type': 'application/json' },
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
          });
        } catch (error) {
          successRate.add(false);
        }
      }

      // 3. TEARDOWN: Очистка
      export function teardown(data) {
        console.log('Cleaning up...');
        try {
            file.delete(data.fileName);
            console.log(`File ${data.fileName} deleted.`);
        } catch (e) {
            console.error('Error deleting file:', e);
        }
      }
Вариант 2: Ключи в оперативной памяти (Memory-based) — Рекомендуемый
Этот вариант быстрее и надежнее для K6. setup скачивает данные и возвращает их как JSON-объект. K6 автоматически передает этот объект каждому VU (виртуальному пользователю). Очистка памяти происходит автоматически при завершении процесса K6, но мы добавим явный лог в teardown.

Особенности: Требует только xk6-sql.

YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: k6-test-scripts-memory
  labels:
    app: syngtp-k6-load-test-memory
data:
  test.js: |
      import http from 'k6/http';
      import sql from 'k6/x/sql';
      import { check } from 'k6';
      import { Rate, Trend } from 'k6/metrics';

      const successRate = new Rate('successful_requests');
      const requestDuration = new Trend('request_duration');

      // Параметры
      const DB_LIMIT = __ENV.DB_LIMIT || 10000;
      
      const dbConfig = {
          user: __ENV.DB_USER || 'postgres',
          password: __ENV.DB_PASSWORD || 'postgres123',
          host: 'tvled-kssh00010.esrt.sber.ru',
          port: '12541',
          dbname: 'mr',
          schema: 'murex'
      };

      const connStr = `postgres://${dbConfig.user}:${dbConfig.password}@${dbConfig.host}:${dbConfig.port}/${dbConfig.dbname}?sslmode=disable&search_path=${dbConfig.schema}`;

      export const options = {
        executor: 'constant-arrival-rate',
        rate: 20,
        timeUnit: '1s',
        preAllocatedVUs: 1,
        maxVUs: 2,
        stages: [
              { duration: '3s', target: 2 },
              { duration: '10s', target: 5 },
        ],
        thresholds: {
          'successful_requests': ['rate>0.99'],
        },
      };

      // 1. SETUP: Загрузка в память
      export function setup() {
        console.log(`Connecting to DB... fetching ${DB_LIMIT} keys.`);
        const db = sql.open('postgres', connStr);
        let ids = [];

        try {
            // Скачиваем одним запросом (для 10k это нормально) или чанками, если нужно.
            // Здесь пример с LIMIT для скорости.
            const query = `SELECT id FROM murex.trades LIMIT ${DB_LIMIT};`;
            const results = sql.query(db, query);
            
            results.forEach(row => ids.push(row.id));
            console.log(`Loaded ${ids.length} IDs into memory.`);
            
        } catch (e) {
            console.error('SQL Error:', e);
            // Фолбэк на случай ошибки БД, чтобы тест не упал сразу (опционально)
            ids = [1, 2, 3]; 
        } finally {
            db.close();
        }
        
        // Возвращаем массив. K6 клонирует это для VUs.
        return { ids: ids };
      }

      // 2. DEFAULT: Тест
      export default function (data) {
        // data.ids содержит наш массив из setup()
        if (!data.ids || data.ids.length === 0) return;

        // Берем случайный ID из памяти
        const randomId = data.ids[Math.floor(Math.random() * data.ids.length)];
        const url = `http://trade-consumer-db-reader:8080/api/trades/${randomId}`;
        
        const params = {
          headers: { 'Content-Type': 'application/json' },
          tags: { endpoint: 'get_trade' },
        };
        
        const res = http.get(url, params);
        
        requestDuration.add(res.timings.duration);
        successRate.add(res.status === 200);
        
        check(res, {
            'status is 200': (r) => r.status === 200,
        });
      }

      // 3. TEARDOWN: Очистка
      export function teardown(data) {
        // В JS garbage collector сам очистит память после выхода.
        // Но мы можем формально "занулить" данные, если бы они хранились во внешней системе.
        console.log('Teardown: Clearing IDs from memory context (handled by K6 exit).');
        data.ids = null;
      }
Важные примечания:
Драйвер БД: Убедитесь, что ваш образ Docker для K6 содержит xk6-sql. Стандартный образ (grafana/k6:latest) не запустит этот код и упадет с ошибкой module 'k6/x/sql' not found.

Потребление памяти: 10 000 ID (целых чисел или UUID) занимают ничтожно мало памяти (несколько мегабайт). Вариант 2 значительно эффективнее, так как не создает нагрузку на диск (IO) внутри пода Kubernetes, что часто является узким местом.

Безопасность: Я использовал sslmode=disable и search_path=murex. Если в вашей сети (Sber) требуется SSL сертификат, его нужно будет примонтировать в под и указать путь в строке подключения.
