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
