Анализ проблемы: WebSocket + Istio Session Affinity
🎯 Корень проблемы
Вы правильно определили направление, но проблема не в коде приложения, а в фундаментальном ограничении браузерного WebSocket API:
Браузерный 
WebSocket
 API не позволяет отправлять кастомные HTTP-заголовки при handshake (Upgrade-запросе).
Это значит, что когда вы поменяли DestinationRule на:
loadBalancer:
  consistentHash:
    httpHeaderName: "sessionId"
    ...это не может работать, потому что фронтендер физически не может добавить заголовок 
sessionId
 к WebSocket handshake из браузера. Ни через 
new WebSocket(url)
, ни через 
@stomp/stompjs
 — это ограничение на уровне стандарта W3C.



🔄 Почему работает после захода на вашу страницу?

Вот что происходит по шагам:
1. Фронтендер открывает ВАШУ страницу → GET /websocket/trades
   ↓
   Istio видит запрос БЕЗ cookie "session-affinity"
   ↓
   Istio выбирает Pod (например, Pod-A), устанавливает cookie:
   Set-Cookie: session-affinity=<hash-pod-A>
   ↓
2. Фронтендер нажимает Connect → WebSocket Upgrade /ws
   ↓
   Браузер АВТОМАТИЧЕСКИ прикрепляет cookie "session-affinity"
   ↓
   Istio направляет на Pod-A → ✅ Соединение работает!
   
3. Фронтендер открывает СВОЮ страницу (тот же домен)
   ↓
   Cookie уже есть в браузере → все запросы идут на Pod-A → ✅ Работает!
   Без предварительного захода:
   1. Фронтендер открывает СВОЮ страницу → WebSocket Upgrade /ws
   ↓
   Cookie "session-affinity" НЕТ
   ↓
   Istio может менять Pod между HTTP Upgrade и последующими фреймами
   ↓
   ❌ Соединение нестабильно или STOMP-сессия теряется
   ✅ Решения

Решение 1: REST-endpoint для инициализации cookie (Рекомендуется)

Создайте лёгкий endpoint, который фронтендер будет вызывать перед подключением WebSocket:

@RestController
public class SessionInitController {

    @GetMapping("/api/ws-init")
    public ResponseEntity<Map<String, String>> initSession() {
        // Этот запрос пройдёт через Istio, 
        // Istio установит cookie "session-affinity"
        return ResponseEntity.ok(Map.of("status", "ready"));
    }
}

Верните обратно DestinationRule на cookie:
loadBalancer:
  consistentHash:
    httpCookie:
      name: 'session-affinity'
      ttl: 3600s
Код фронтендера (перед подключением):
async connect() {
    // 1. Сначала получаем cookie через обычный HTTP запрос
    await fetch('https://websocket-istio-test.msgtp-ift-k8s-geo.delta.sbrf.ru/api/ws-init', {
        credentials: 'include'  // ← ВАЖНО: включает отправку/получение cookies
    });
    
    // 2. Теперь подключаем WebSocket (cookie автоматически прикрепится)
    this.initializeStompClient();
    this.stompClient.activate();
}
Решение 2: Использовать 
useSourceIp
 вместо cookie

Если не хотите менять код фронтенда, привяжите affinity к IP-адресу клиента:
loadBalancer:
  consistentHash:
    useSourceIp: true
    
Решение 3: Cookie через VirtualService

Настройте VirtualService так, чтобы он устанавливал cookie на любой первый запрос:
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: websocket-istio-test
spec:
  hosts:
    - websocket-istio-test.msgtp-ift-k8s-geo.delta.sbrf.ru
  http:
    - match:
        - uri:
            prefix: /ws
      route:
        - destination:
            host: websocket-istio-test
            subset: mtls-8080
            port:
              number: 8080
      # Важно для WebSocket:
      websocketUpgrade: true
    - route:
        - destination:
            host: websocket-istio-test
            subset: mtls-8080
            port:
              number: 8080
⚠️ Дополнительно: проверьте VirtualService на поддержку WebSocket

В вашем текущем VirtualService обязательно должно быть разрешение WebSocket upgrade:
# Для Istio < 1.15
- route:
    - destination:
        host: websocket-istio-test
  websocketUpgrade: true

# Для Istio >= 1.15 (автоматически поддерживается, но можно явно)
- match:
    - headers:
        upgrade:
          exact: websocket
  route:
    - destination:
        host: websocket-istio-test
Без этого Istio/Envoy может не пропускать 
Connection: Upgrade
 и WebSocket не установится.



📋 Итоговый чеклист

Шаг	Действие	Статус
1	Вернуть 
httpCookie
 в DestinationRule	⬜
2	Создать 
/api/ws-init
 endpoint	⬜
3	Фронтендер вызывает 
fetch('/api/ws-init', {credentials: 'include'})
 перед 
WebSocket
⬜
4	Проверить что VirtualService поддерживает WebSocket upgrade	⬜
5	Убедиться что фронт-страница на том же домене (иначе cookie не отправится)	⬜

Решение 1 — самое надёжное и правильное. Один 
fetch
 перед подключением полностью решает проблему.



Почему cookie генерируются только вашей страницей
🔍 Механизм: кто генерирует cookie?
Cookie генерирует не ваша страница и не ваше приложение, а Envoy (Istio sidecar). Вот как это работает:

Когда в DestinationRule настроено:
  consistentHash:
    httpCookie:
      name: 'session-affinity'
      ttl: 3600s

Envoy АВТОМАТИЧЕСКИ:
1. Видит входящий HTTP-запрос БЕЗ cookie "session-affinity"
2. Выбирает Pod
3. Добавляет в ОТВЕТ заголовок: Set-Cookie: session-affinity=<hash>
4. Браузер сохраняет эту cookie
      
🎯 Вот в чём разница между вашими страницами

Ваша страница — работает ✅

Шаг 1: GET /websocket/trades  ← ОБЫЧНЫЙ HTTP-запрос!
        ↓
        Envoy: "Cookie нет → выбираю Pod-A"
        ↓
        Ответ: 200 OK + Set-Cookie: session-affinity=abc123
        ↓
        Браузер: СОХРАНЯЕТ cookie ✅

Шаг 2: WebSocket Upgrade /ws
        ↓
        Браузер АВТОМАТИЧЕСКИ прикрепляет: Cookie: session-affinity=abc123
        ↓
        Envoy: "Cookie есть → направляю на Pod-A" ✅

Страница фронтендера — НЕ работает ❌
Шаг 1: WebSocket Upgrade /ws  ← СРАЗУ WebSocket, без предварительного HTTP!
        ↓
        Envoy: "Cookie нет → выбираю Pod-A"
        ↓
        Ответ: 101 Switching Protocols + Set-Cookie: session-affinity=abc123
        ↓
        Браузер: ИГНОРИРУЕТ Set-Cookie из ответа 101 ❌❌❌
⚡ Ключевая проблема


Браузеры игнорируют 
Set-Cookie
 в ответе 
101 Switching Protocols
.


Это известное поведение — cookie устанавливаются только из обычных HTTP-ответов (200, 301, 302 и т.д.), но не из 101 Switching Protocols.



Именно поэтому:

Ваша страница сначала делает
GET /websocket/trades
(обычный HTTP → cookie сохраняется), а потом WebSocket
Страница фронтендера сразу делает WebSocket (101 → cookie НЕ сохраняется)
После захода на вашу страницу cookie уже есть в браузере → страница фронтендера начинает работать


✅ Решения (несколько вариантов, выберите удобный)

Вариант 1: REST-endpoint для "прогрева" cookie (самый надёжный)

На бэкенде добавьте:

@RestController
public class SessionInitController {

    @GetMapping("/api/ws-init")
    public ResponseEntity<Map<String, String>> initSession() {
        // Тело не важно. Важно что это обычный HTTP-запрос,
        // и Envoy добавит Set-Cookie в ответ.
        return ResponseEntity.ok(Map.of("status", "ready"));
    }
}

Фронтендер должен вызвать ДО подключения WebSocket:
async connect() {
    // 1. Обычный HTTP → Envoy установит cookie
    await fetch('/api/ws-init', { 
        credentials: 'include'   // ← ОБЯЗАТЕЛЬНО для cross-origin
    });
    
    // 2. Теперь WebSocket — cookie уже в браузере
    this.initializeStompClient();
    this.stompClient.activate();
}
