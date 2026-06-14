Коротко: **фронтендер в целом прав**. WebSocket/STOMP-соединение **не должно требовать предварительного открытия отдельной REST-страницы**. Если после открытия вашей отладочной страницы WebSocket начинает работать, значит эта страница побочно делает что-то важное: ставит cookie, создаёт HTTP-сессию, получает CSRF-токен, прогревает приложение, проходит авторизацию, инициализирует SockJS endpoint и т.п. Это либо баг, либо неявное требование backend/infra, которое нужно убрать или сделать явным.

## Как WebSocket устанавливается на самом деле

WebSocket работает поверх TCP, но стартует он как обычный HTTP-запрос с заголовком `Upgrade`.

Упрощённо браузер делает:

```http
GET /ws HTTP/1.1
Host: api.example.com
Upgrade: websocket
Connection: Upgrade
Origin: https://frontend.example.com
Sec-WebSocket-Key: ...
Sec-WebSocket-Version: 13
```

Если backend/ingress всё разрешает, сервер отвечает:

```http
HTTP/1.1 101 Switching Protocols
Upgrade: websocket
Connection: Upgrade
```

После этого TCP-соединение становится WebSocket-соединением, а поверх него уже может идти STOMP.

То есть **отдельный REST-вызов для открытия WebSocket не нужен**.

---

## Почему у вас начинает работать только после открытия REST-страницы

Сам факт, что после открытия debug-страницы всё начинает работать, почти наверняка означает, что эта страница создаёт какое-то состояние в браузере или на сервере.

Наиболее частые причины:

### 1. Debug-страница ставит `JSESSIONID`

Например, при открытии страницы Spring Boot создаёт HTTP-сессию и отдаёт cookie:

```http
Set-Cookie: JSESSIONID=...; Path=/; HttpOnly
```

Потом WebSocket-запрос уже идёт с этой cookie:

```http
Cookie: JSESSIONID=...
```

И backend его принимает.

До открытия страницы cookie нет — handshake получает `403`, `401` или другой отказ.

Это частая проблема, если WebSocket-код завязан на `HttpSession`.

---

### 2. Debug-страница выдаёт CSRF-токен

Если у вас Spring Security и включён CSRF, может быть такая схема:

1. REST-страница отдаёт `XSRF-TOKEN`.
2. Браузер сохраняет cookie.
3. WebSocket/STOMP `CONNECT` проходит, потому что токен появился.

Без предварительной страницы токена нет, соединение не устанавливается.

---

### 3. Debug-страница выполняет авторизацию

Например, при заходе на debug-страницу происходит редирект на SSO/OAuth2/Login, после чего браузер получает auth-cookie.

Тогда проблема не в WebSocket как таковом, а в том, что WebSocket требует авторизованную сессию, но frontend её заранее не создаёт.

---

### 4. Неправильно настроены `Origin`, CORS или Spring WebSocket allowed origins

WebSocket не использует CORS в точности как обычный `fetch`, но браузер отправляет заголовок:

```http
Origin: https://frontend.example.com
```

Spring может отклонять handshake, если origin не разрешён.

Например, нужно явно разрешить frontend-origin:

```java
@Configuration
@EnableWebSocketMessageBroker
public class WebSocketConfig implements WebSocketMessageBrokerConfigurer {

    @Override
    public void registerStompEndpoints(StompEndpointRegistry registry) {
        registry.addEndpoint("/ws")
                .setAllowedOriginPatterns("https://frontend.example.com");
    }

    @Override
    public void configureMessageBroker(MessageBrokerRegistry registry) {
        registry.enableSimpleBroker("/topic", "/queue");
        registry.setApplicationDestinationPrefixes("/app");
    }
}
```

Для разработки иногда ставят:

```java
.setAllowedOriginPatterns("*")
```

Но для production лучше указывать конкретные домены.

---

### 5. Несовпадение SockJS/native WebSocket

Если backend зарегистрирован так:

```java
registry.addEndpoint("/ws")
        .setAllowedOriginPatterns("https://frontend.example.com")
        .withSockJS();
```

то frontend должен подключаться через SockJS-клиент, например:

```javascript
const socket = new SockJS('https://api.example.com/ws');
const stompClient = Stomp.over(socket);
```

А если frontend использует нативный WebSocket:

```javascript
new WebSocket('wss://api.example.com/ws');
```

то backend endpoint должен быть без SockJS:

```java
registry.addEndpoint("/ws")
        .setAllowedOriginPatterns("https://frontend.example.com");
```

Хорошая практика — завести два разных endpoint:

```java
@Override
public void registerStompEndpoints(StompEndpointRegistry registry) {
    registry.addEndpoint("/ws")
            .setAllowedOriginPatterns("https://frontend.example.com");

    registry.addEndpoint("/ws-sockjs")
            .setAllowedOriginPatterns("https://frontend.example.com")
            .withSockJS();
}
```

Тогда:

```javascript
// Native WebSocket
const client = new Client({
  brokerURL: 'wss://api.example.com/ws'
});
```

или:

```javascript
// SockJS
const client = new Client({
  webSocketFactory: () => new SockJS('https://api.example.com/ws-sockjs')
});
```

Важно: если используется SockJS, запросы вида:

```text
/ws-sockjs/info
/ws-sockjs/{server-id}/{session-id}/websocket
```

— это нормально. Это служебные HTTP-запросы SockJS, но frontend-клиент должен выполнять их сам. Руками открывать вашу REST-страницу всё равно не нужно.

---

## Как правильно передать `ClientId`

Есть несколько вариантов.

## Вариант 1. Передать `clientId` в query string при WebSocket handshake

Frontend:

```javascript
const clientId = 'client-123';

const client = new Client({
  brokerURL: `wss://api.example.com/ws?clientId=${encodeURIComponent(clientId)}`,

  onConnect: () => {
    console.log('Connected');
  }
});

client.activate();
```

Backend может прочитать `clientId` на handshake-этапе через `HandshakeInterceptor`:

```java
@Component
public class ClientIdHandshakeInterceptor implements HandshakeInterceptor {

    @Override
    public boolean beforeHandshake(
            ServerHttpRequest request,
            ServerHttpResponse response,
            WebSocketHandler wsHandler,
            Map<String, Object> attributes
    ) {
        URI uri = request.getURI();
        String query = uri.getQuery();

        if (query != null) {
            UriComponents components = UriComponentsBuilder.fromUri(uri).build();
            String clientId = components.getQueryParams().getFirst("clientId");

            if (clientId != null && !clientId.isBlank()) {
                attributes.put("clientId", clientId);
            }
        }

        return true;
    }

    @Override
    public void afterHandshake(
            ServerHttpRequest request,
            ServerHttpResponse response,
            WebSocketHandler wsHandler,
            Exception exception
    ) {
    }
}
```

Регистрация:

```java
@Configuration
@EnableWebSocketMessageBroker
public class WebSocketConfig implements WebSocketMessageBrokerConfigurer {

    private final ClientIdHandshakeInterceptor clientIdHandshakeInterceptor;

    public WebSocketConfig(ClientIdHandshakeInterceptor clientIdHandshakeInterceptor) {
        this.clientIdHandshakeInterceptor = clientIdHandshakeInterceptor;
    }

    @Override
    public void registerStompEndpoints(StompEndpointRegistry registry) {
        registry.addEndpoint("/ws")
                .addInterceptors(clientIdHandshakeInterceptor)
                .setAllowedOriginPatterns("https://frontend.example.com");
    }
}
```

Плюс этого варианта: `clientId` доступен уже во время WebSocket handshake.

Минус: query string часто попадает в access logs ingress/nginx/istio, поэтому не стоит передавать там чувствительные секреты.

---

## Вариант 2. Передать `clientId` в STOMP `CONNECT` headers

Это часто более правильный вариант для STOMP.

Frontend:

```javascript
const client = new Client({
  brokerURL: 'wss://api.example.com/ws',

  connectHeaders: {
    clientId: 'client-123'
  },

  onConnect: () => {
    console.log('Connected');
  }
});

client.activate();
```

Backend:

```java
@Component
public class StompConnectInterceptor implements ChannelInterceptor {

    @Override
    public Message<?> preSend(Message<?> message, MessageChannel channel) {
        StompHeaderAccessor accessor = MessageHeaderAccessor.getAccessor(
                message,
                StompHeaderAccessor.class
        );

        if (accessor != null && StompCommand.CONNECT.equals(accessor.getCommand())) {
            String clientId = accessor.getFirstNativeHeader("clientId");

            if (clientId == null || clientId.isBlank()) {
                throw new IllegalArgumentException("Missing clientId");
            }

            accessor.getSessionAttributes().put("clientId", clientId);
        }

        return message;
    }
}
```

Регистрация interceptor:

```java
@Configuration
@EnableWebSocketMessageBroker
public class WebSocketConfig implements WebSocketMessageBrokerConfigurer {

    private final StompConnectInterceptor stompConnectInterceptor;

    public WebSocketConfig(StompConnectInterceptor stompConnectInterceptor) {
        this.stompConnectInterceptor = stompConnectInterceptor;
    }

    @Override
    public void configureClientInboundChannel(ChannelRegistration registration) {
        registration.interceptors(stompConnectInterceptor);
    }

    @Override
    public void registerStompEndpoints(StompEndpointRegistry registry) {
        registry.addEndpoint("/ws")
                .setAllowedOriginPatterns("https://frontend.example.com");
    }
}
```

Важный нюанс: STOMP `CONNECT` headers идут **после** открытия WebSocket-соединения. То есть если вам нужно принять/отклонить клиента именно на handshake-этапе, используйте query string, cookie или кастомный handshake mechanism.

---

## Вариант 3. Не использовать `ClientId` как auth, а использовать нормальный токен

Если `ClientId` нужен для идентификации клиента, но есть ещё и безопасность, лучше схема такая:

- `clientId` — публичный идентификатор клиента.
- `accessToken`/JWT — подтверждение, что клиент имеет право подключаться.

Например:

```javascript
const client = new Client({
  brokerURL: 'wss://api.example.com/ws',

  connectHeaders: {
    clientId: 'client-123',
    Authorization: `Bearer ${accessToken}`
  }
});
```

Но важно: браузерный `WebSocket` API **не позволяет поставить произвольные HTTP headers на handshake**, например `Authorization`. Поэтому `Authorization` в примере выше — это не HTTP header handshake, а STOMP header в кадре `CONNECT`.

Если нужно авторизовать до handshake, обычно используют:

```text
wss://api.example.com/ws?token=...
```

или cookie-based auth.

---

## Что проверить в браузере

Откройте DevTools → Network → WS.

Сравните два сценария:

1. До открытия debug-страницы.
2. После открытия debug-страницы.

Смотрите:

- URL WebSocket-запроса.
- Status code:
  - `101` — handshake успешен.
  - `400` — неправильный handshake, путь, SockJS/native mismatch.
  - `401` — нет авторизации.
  - `403` — forbidden, часто origin/CSRF/auth.
  - `404` — ingress/path/rewrite не туда.
  - `426` — требуется upgrade.
- Есть ли `Cookie`.
- Есть ли `JSESSIONID`.
- Есть ли `XSRF-TOKEN`.
- Какой `Origin`.
- Какой путь: `/ws`, `/ws/websocket`, `/ws/info`, etc.
- Используется `ws://` или `wss://`.

Если frontend-сайт открыт по HTTPS, WebSocket должен быть:

```text
wss://...
```

а не:

```text
ws://...
```

Иначе браузер может заблокировать mixed content.

---

## Что проверить на backend

Добавьте логирование handshake:

```java
@Component
public class LoggingHandshakeInterceptor implements HandshakeInterceptor {

    private static final Logger log = LoggerFactory.getLogger(LoggingHandshakeInterceptor.class);

    @Override
    public boolean beforeHandshake(
            ServerHttpRequest request,
            ServerHttpResponse response,
            WebSocketHandler wsHandler,
            Map<String, Object> attributes
    ) {
        log.info("WS handshake uri={}", request.getURI());
        log.info("WS handshake headers={}", request.getHeaders());

        return true;
    }

    @Override
    public void afterHandshake(
            ServerHttpRequest request,
            ServerHttpResponse response,
            WebSocketHandler wsHandler,
            Exception exception
    ) {
        if (exception != null) {
            log.warn("WS handshake failed", exception);
        }
    }
}
```

И подключите:

```java
@Override
public void registerStompEndpoints(StompEndpointRegistry registry) {
    registry.addEndpoint("/ws")
            .addInterceptors(loggingHandshakeInterceptor)
            .setAllowedOriginPatterns("https://frontend.example.com");
}
```

После этого станет видно, что отличается до и после открытия REST-страницы.

---

## Что проверить в `ingress-nginx`

Для WebSocket обычно нужны нормальные timeout-ы. Ingress-nginx обычно поддерживает WebSocket автоматически, но timeout лучше выставить:

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-connect-timeout: "60"
```

Пример:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-ingress
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-connect-timeout: "60"
spec:
  ingressClassName: nginx
  rules:
    - host: api.example.com
      http:
        paths:
          - path: /ws
            pathType: Prefix
            backend:
              service:
                name: app-service
                port:
                  number: 8080
```

Если используете SockJS, важно, чтобы route покрывал не только `/ws`, но и вложенные пути:

```text
/ws/info
/ws/{server-id}/{session-id}/websocket
/ws/{server-id}/{session-id}/xhr_streaming
```

То есть нужен `pathType: Prefix`.

---

## Что проверить в Istio

WebSocket через Istio обычно работает, но проверьте:

- route не режет путь;
- timeout не слишком маленький;
- не включены политики, которые ломают upgrade;
- VirtualService маршрутизирует `/ws` и все подпути, если SockJS.

Примерно:

```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: app-vs
spec:
  hosts:
    - api.example.com
  gateways:
    - app-gateway
  http:
    - match:
        - uri:
            prefix: /ws
      route:
        - destination:
            host: app-service
            port:
              number: 8080
      timeout: 0s
```

---

## Как я бы чинил

### Шаг 1. Убрать зависимость WebSocket от debug-страницы

WebSocket endpoint должен открываться напрямую:

```text
wss://api.example.com/ws
```

REST-страница не должна быть частью production flow.

---

### Шаг 2. Явно решить, как передаётся `ClientId`

Например:

```javascript
const client = new Client({
  brokerURL: 'wss://api.example.com/ws',
  connectHeaders: {
    clientId: clientId
  }
});
```

На backend принимать `clientId` в STOMP `CONNECT`.

---

### Шаг 3. Если нужна авторизация — сделать её явной

Например:

```javascript
const client = new Client({
  brokerURL: 'wss://api.example.com/ws',
  connectHeaders: {
    clientId: clientId,
    Authorization: `Bearer ${accessToken}`
  }
});
```

И валидировать это в `ChannelInterceptor`.

---

### Шаг 4. Если сейчас всё завязано на `JSESSIONID`, убрать или правильно инициализировать session

Плохой вариант:

```text
Сначала открой /debug-page, потом подключай WebSocket.
```

Нормальный вариант:

```text
Frontend явно логинится / получает токен / получает cookie, потом подключает WebSocket.
```

Или stateless-вариант:

```text
Frontend подключает WebSocket и передаёт JWT в STOMP CONNECT.
```

---

## Кто прав

Формально:

- Вы правы, что WebSocket работает поверх TCP и начинается через HTTP Upgrade.
- Но фронтендер прав в главном: **WebSocket-соединение не должно требовать предварительного открытия отдельной REST-страницы**.

Если REST-ручка нужна только потому, что она создаёт cookie/session/CSRF/auth-состояние, то это проблема архитектуры или конфигурации backend/security/infra.

Правильное поведение должно быть таким:

```text
Frontend сам открывает WebSocket/STOMP соединение.
Frontend передаёт clientId явно.
Backend принимает или отклоняет соединение по понятным правилам.
Никакая debug HTML-страница не требуется.
```

---

## Самый вероятный диагноз

По вашему описанию самый вероятный сценарий такой:

```text
Debug REST page создаёт JSESSIONID или CSRF/auth cookie.
После этого WebSocket handshake проходит.
Без этой cookie backend/Spring Security отклоняет соединение.
```

Проверьте это в DevTools: сравните WebSocket request headers до и после открытия debug-страницы. Если после открытия страницы появляется `Cookie: JSESSIONID=...` или `XSRF-TOKEN=...`, причина почти найдена.
