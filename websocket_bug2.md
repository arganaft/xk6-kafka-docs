По вашим классам: **REST-ручка `GET /websocket/trades` вообще не должна участвовать в установлении WebSocket/STOMP-соединения**. Ваш реальный WebSocket endpoint — это:

```text
/ws
```

То есть frontend должен подключаться напрямую к:

```text
wss://ваш-host/ws
```

а не сначала открывать:

```text
https://ваш-host/websocket/trades
```

Если без открытия debug-страницы frontend не может подключиться, значит есть один из следующих вариантов:

1. frontend подключается не туда / не тем протоколом;
2. frontend использует SockJS, а backend у вас настроен на native WebSocket;
3. debug-страница создаёт cookie/session/auth-состояние;
4. frontend не передаёт `ClientId` в STOMP `CONNECT`;
5. вы портите STOMP `CONNECTED` frame в `configureClientOutboundChannel`;
6. проблема в ingress/Istio/security, а не в самой REST-ручке.

---

# Главный вывод

**Фронтендер прав в том, что WebSocket должен устанавливаться без вызова REST-страницы.**

Но по вашему коду я бы сказал так:

> Сам по себе backend endpoint `/ws` может принимать WebSocket напрямую. Если frontend не может подключиться, нужно смотреть, как именно он подключается и что происходит в Network/WS. В вашем backend-коде есть несколько мест, которые лучше поправить.

---

# Что у вас сейчас есть

## REST-страница

```java
@GetMapping("/websocket/trades")
public String getTradesPage() {
    return "index";
}
```

Это просто отдача HTML-страницы.

Она **не нужна** для WebSocket handshake.

---

## WebSocket/STOMP endpoint

```java
@Override
public void registerStompEndpoints(StompEndpointRegistry registry) {
    registry.addEndpoint("/ws")
            .setAllowedOriginPatterns("*");
}
```

Это значит, что frontend должен подключаться так:

```javascript
const socket = new WebSocket('wss://your-host/ws');
const stompClient = Stomp.over(socket);
```

Или если локально:

```javascript
const socket = new WebSocket('ws://localhost:8080/ws');
const stompClient = Stomp.over(socket);
```

---

# Важная проблема в debug-странице

У вас в HTML есть поле:

```html
<input type="text" class="form-control" id="wsEndpoint" value="wss://websocket-istio-test.msgtp-ift-k8s-geo.delta.sbrf.ru">
```

Но в JS это поле **не используется**.

Вы реально подключаетесь вот сюда:

```javascript
var wsBaseUrl = "ws://localhost:8080";

function connect() {
    var socket = new WebSocket(wsBaseUrl + '/ws');
    stompClient = Stomp.over(socket);
}
```

То есть значение из input `wsEndpoint` игнорируется.

Правильнее сделать так:

```javascript
function connect() {
    var wsBaseUrl = document.getElementById('wsEndpoint').value;
    var socket = new WebSocket(wsBaseUrl + '/ws');

    stompClient = Stomp.over(socket);

    stompClient.connect({}, function (frame) {
        setConnected(true);
        console.log('✅ Connected: ' + frame);

        stompClient.subscribe('/user/topic/trades', function (message) {
            console.log('📨 MESSAGE ARRIVED:', message);
            log("RECEIVED: " + message.body);
        });
    }, function (error) {
        console.error('❌ Connection error:', error);
        log("ERROR: " + error);
        setConnected(false);
    });
}
```

Тогда если в поле указано:

```text
wss://websocket-istio-test.msgtp-ift-k8s-geo.delta.sbrf.ru
```

реальное подключение будет к:

```text
wss://websocket-istio-test.msgtp-ift-k8s-geo.delta.sbrf.ru/ws
```

---

# Вторая важная проблема: SockJS

В debug-странице вы подключаете библиотеку SockJS:

```html
<script src="https://cdnjs.cloudflare.com/ajax/libs/sockjs-client/1.6.1/sockjs.min.js"></script>
```

Но фактически используете native WebSocket:

```javascript
var socket = new WebSocket(wsBaseUrl + '/ws');
stompClient = Stomp.over(socket);
```

А backend у вас тоже настроен под native WebSocket:

```java
registry.addEndpoint("/ws")
        .setAllowedOriginPatterns("*");
```

То есть сейчас у вас **не SockJS**.

Если frontend-разработчик использует такой код:

```javascript
const socket = new SockJS('https://your-host/ws');
const stompClient = Stomp.over(socket);
```

то у вас backend для этого **не настроен**.

Для SockJS endpoint должен быть зарегистрирован так:

```java
registry.addEndpoint("/ws")
        .setAllowedOriginPatterns("*")
        .withSockJS();
```

Но если хотите использовать native WebSocket, тогда frontend должен использовать:

```javascript
const socket = new WebSocket('wss://your-host/ws');
const stompClient = Stomp.over(socket);
```

## Нужно договориться с фронтендером

Либо native WebSocket:

Backend:

```java
registry.addEndpoint("/ws")
        .setAllowedOriginPatterns("*");
```

Frontend:

```javascript
const socket = new WebSocket('wss://your-host/ws');
const stompClient = Stomp.over(socket);
```

Либо SockJS:

Backend:

```java
registry.addEndpoint("/ws")
        .setAllowedOriginPatterns("*")
        .withSockJS();
```

Frontend:

```javascript
const socket = new SockJS('https://your-host/ws');
const stompClient = Stomp.over(socket);
```

Обратите внимание: для SockJS используется URL с `https://`, а не `wss://`.

---

# Третья проблема: вы неправильно передаёте sessionId в `CONNECT_ACK`

Вот этот код я бы убрал:

```java
@Override
public void configureClientOutboundChannel(ChannelRegistration registration) {
    registration.interceptors(new ChannelInterceptor() {
        @Override
        public Message<?> preSend(Message<?> message, MessageChannel channel) {

            StompHeaderAccessor accessor =
                    StompHeaderAccessor.wrap(message);

            if (SimpMessageType.CONNECT_ACK.equals(accessor.getMessageType())) {
                String sessionId = (String) message.getHeaders().get("simpSessionId");
                ConnectedEvent connectedEvent = new ConnectedEvent(sessionId);

                byte[] obje = null;
                try {
                    obje = objectMapper.writeValueAsBytes(connectedEvent);
                } catch (JsonProcessingException e) {
                    throw new RuntimeException(e);
                }
                return MessageBuilder.createMessage(
                        obje,
                        message.getHeaders()
                );
            }
            return message;
        }
    });
}
```

Вы меняете тело системного STOMP-сообщения `CONNECTED`.

Это плохая идея.

STOMP `CONNECTED` frame не стоит использовать как бизнес-сообщение. Разные STOMP-клиенты могут по-разному реагировать на тело в `CONNECTED`. У одного клиента это может случайно работать, у другого — нет.

Лучше отправлять `sessionId` отдельным сообщением после подключения.

Например:

```java
@Component
@RequiredArgsConstructor
public class WebSocketEventsListener {

    private final SimpMessagingTemplate messagingTemplate;

    @EventListener
    public void handleSessionConnected(SessionConnectEvent event) {
        StompHeaderAccessor accessor = StompHeaderAccessor.wrap(event.getMessage());

        String sessionId = accessor.getSessionId();

        if (sessionId == null) {
            return;
        }

        SimpMessageHeaderAccessor headers = SimpMessageHeaderAccessor.create();
        headers.setSessionId(sessionId);
        headers.setLeaveMutable(true);

        messagingTemplate.convertAndSendToUser(
                sessionId,
                "/queue/connected",
                new ConnectedEvent(sessionId),
                headers.getMessageHeaders()
        );
    }
}
```

Frontend тогда подписывается:

```javascript
stompClient.subscribe('/user/queue/connected', function (message) {
    const connectedEvent = JSON.parse(message.body);
    console.log('Server sessionId:', connectedEvent.sessionId);
});
```

Но ещё лучше — **не заставлять frontend зависеть от server-side `sessionId`**. Пусть frontend передаёт свой `ClientId`.

---

# Как правильно передать `ClientId`

Вы писали:

> при первом обращении фронт должен передать значение `ClientId`, чтобы я мог идентифицировать его

В STOMP это обычно делается через `CONNECT` headers.

## Frontend

Например, если используете старый `stomp.js`:

```javascript
const socket = new WebSocket('wss://your-host/ws');
const stompClient = Stomp.over(socket);

stompClient.connect(
    {
        clientId: 'client-123'
    },
    function (frame) {
        console.log('Connected:', frame);

        stompClient.subscribe('/user/topic/trades', function (message) {
            console.log('Message:', message.body);
        });

        stompClient.send('/app/config', {}, JSON.stringify({
            type: 'SetViewConfiguration',
            data: {
                requestId: '123'
            }
        }));
    },
    function (error) {
        console.error('Connection error:', error);
    }
);
```

Если используете современный `@stomp/stompjs`:

```javascript
import { Client } from '@stomp/stompjs';

const client = new Client({
    brokerURL: 'wss://your-host/ws',

    connectHeaders: {
        clientId: 'client-123'
    },

    onConnect: () => {
        console.log('Connected');

        client.subscribe('/user/topic/trades', message => {
            console.log('Message:', message.body);
        });

        client.publish({
            destination: '/app/config',
            body: JSON.stringify({
                type: 'SetViewConfiguration',
                data: {
                    requestId: '123'
                }
            })
        });
    },

    onStompError: frame => {
        console.error('Broker error:', frame.headers['message']);
        console.error(frame.body);
    },

    onWebSocketError: event => {
        console.error('WebSocket error:', event);
    }
});

client.activate();
```

---

# Backend: принять `ClientId` из STOMP `CONNECT`

Добавьте inbound interceptor:

```java
package com.pivotService.config;

import lombok.extern.slf4j.Slf4j;
import org.springframework.messaging.Message;
import org.springframework.messaging.MessageChannel;
import org.springframework.messaging.simp.stomp.StompCommand;
import org.springframework.messaging.simp.stomp.StompHeaderAccessor;
import org.springframework.messaging.support.ChannelInterceptor;
import org.springframework.messaging.support.MessageHeaderAccessor;
import org.springframework.stereotype.Component;

@Component
@Slf4j
public class ClientIdStompInterceptor implements ChannelInterceptor {

    @Override
    public Message<?> preSend(Message<?> message, MessageChannel channel) {
        StompHeaderAccessor accessor = MessageHeaderAccessor.getAccessor(
                message,
                StompHeaderAccessor.class
        );

        if (accessor == null) {
            return message;
        }

        if (StompCommand.CONNECT.equals(accessor.getCommand())) {
            String clientId = accessor.getFirstNativeHeader("clientId");

            if (clientId == null || clientId.isBlank()) {
                throw new IllegalArgumentException("Missing required STOMP header: clientId");
            }

            accessor.getSessionAttributes().put("clientId", clientId);

            log.info(
                    "WebSocket STOMP CONNECT: sessionId={}, clientId={}",
                    accessor.getSessionId(),
                    clientId
            );
        }

        return message;
    }
}
```

И зарегистрируйте его:

```java
@Override
public void configureClientInboundChannel(ChannelRegistration registration) {
    registration.interceptors(clientIdStompInterceptor);
}
```

Полный пример:

```java
@Configuration
@EnableWebSocketMessageBroker
public class WebSocketConfig implements WebSocketMessageBrokerConfigurer {

    private final ClientIdStompInterceptor clientIdStompInterceptor;

    public WebSocketConfig(ClientIdStompInterceptor clientIdStompInterceptor) {
        this.clientIdStompInterceptor = clientIdStompInterceptor;
    }

    @Override
    public void registerStompEndpoints(StompEndpointRegistry registry) {
        registry.addEndpoint("/ws")
                .setAllowedOriginPatterns("*");
    }

    @Override
    public void configureClientInboundChannel(ChannelRegistration registration) {
        registration.interceptors(clientIdStompInterceptor);
    }

    @Override
    public void configureMessageBroker(MessageBrokerRegistry registry) {
        ThreadPoolTaskScheduler taskScheduler = new ThreadPoolTaskScheduler();
        taskScheduler.setPoolSize(1);
        taskScheduler.setThreadNamePrefix("heartbeat-");
        taskScheduler.initialize();

        registry.enableSimpleBroker("/topic", "/queue")
                .setTaskScheduler(taskScheduler)
                .setHeartbeatValue(new long[]{10000, 10000});

        registry.setApplicationDestinationPrefixes("/app");
        registry.setUserDestinationPrefix("/user");
    }
}
```

И из контроллера можно получить `clientId` так:

```java
@MessageMapping("/config")
public void handleClientRequest(
        @Payload JsonNode request,
        SimpMessageHeaderAccessor headerAccessor
) throws SQLException {
    String sessionId = headerAccessor.getSessionId();

    String clientId = null;
    if (headerAccessor.getSessionAttributes() != null) {
        clientId = (String) headerAccessor.getSessionAttributes().get("clientId");
    }

    log.info("Config request: sessionId={}, clientId={}", sessionId, clientId);

    requestProcessDispatcher.dispatchClientRequest(request, headerAccessor);
}
```

---

# Важно: STOMP headers — это не HTTP headers

Если frontend пишет так:

```javascript
stompClient.connect(
    {
        clientId: 'client-123'
    },
    onConnect,
    onError
);
```

то `clientId` уйдёт не в HTTP handshake, а в STOMP frame `CONNECT`.

То есть сначала будет WebSocket handshake:

```http
GET /ws HTTP/1.1
Upgrade: websocket
Connection: Upgrade
```

А потом внутри WebSocket уйдёт STOMP frame:

```text
CONNECT
accept-version:1.1,1.0
heart-beat:10000,10000
clientId:client-123

^@
```

Для вашего случая это нормально.

Если вам нужно получить `ClientId` именно во время HTTP WebSocket handshake, тогда надо передавать его в query string:

```javascript
const clientId = 'client-123';
const socket = new WebSocket(
    'wss://your-host/ws?clientId=' + encodeURIComponent(clientId)
);
const stompClient = Stomp.over(socket);
```

И на backend читать через `HandshakeInterceptor`.

Но если `ClientId` не секретный, STOMP `CONNECT` headers обычно удобнее.

---

# Исправленный вариант вашего `WebSocketConfig`

Я бы сделал примерно так:

```java
package com.pivotService.config;

import lombok.RequiredArgsConstructor;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.messaging.simp.config.ChannelRegistration;
import org.springframework.messaging.simp.config.MessageBrokerRegistry;
import org.springframework.scheduling.concurrent.ThreadPoolTaskScheduler;
import org.springframework.web.socket.config.annotation.EnableWebSocketMessageBroker;
import org.springframework.web.socket.config.annotation.StompEndpointRegistry;
import org.springframework.web.socket.config.annotation.WebSocketMessageBrokerConfigurer;

@Configuration
@EnableWebSocketMessageBroker
@RequiredArgsConstructor
public class WebSocketConfig implements WebSocketMessageBrokerConfigurer {

    private final ClientIdStompInterceptor clientIdStompInterceptor;

    @Override
    public void registerStompEndpoints(StompEndpointRegistry registry) {
        registry.addEndpoint("/ws")
                .setAllowedOriginPatterns("*");
    }

    @Override
    public void configureClientInboundChannel(ChannelRegistration registration) {
        registration.interceptors(clientIdStompInterceptor);
    }

    @Override
    public void configureMessageBroker(MessageBrokerRegistry registry) {
        registry.enableSimpleBroker("/topic", "/queue")
                .setTaskScheduler(webSocketHeartbeatScheduler())
                .setHeartbeatValue(new long[]{10000, 10000});

        registry.setApplicationDestinationPrefixes("/app");
        registry.setUserDestinationPrefix("/user");
    }

    @Bean
    public ThreadPoolTaskScheduler webSocketHeartbeatScheduler() {
        ThreadPoolTaskScheduler taskScheduler = new ThreadPoolTaskScheduler();
        taskScheduler.setPoolSize(1);
        taskScheduler.setThreadNamePrefix("websocket-heartbeat-");
        taskScheduler.initialize();
        return taskScheduler;
    }
}
```

Обратите внимание: я убрал:

```java
@EnableWebSocket
```

Оставьте только:

```java
@EnableWebSocketMessageBroker
```

Для STOMP over WebSocket `@EnableWebSocket` отдельно не нужен.

---

# Исправленный debug frontend

```html
<script>
    var stompClient = null;

    function setConnected(connected) {
        document.getElementById('connect').disabled = connected;
        document.getElementById('disconnect').disabled = !connected;
        document.getElementById('send').disabled = !connected;
        document.getElementById('status').className = connected ? 'badge bg-success ms-2' : 'badge bg-secondary ms-2';
        document.getElementById('status').innerText = connected ? 'Connected' : 'Disconnected';
    }

    function connect() {
        var wsBaseUrl = document.getElementById('wsEndpoint').value;
        var clientId = 'debug-client-' + Date.now();

        var socket = new WebSocket(wsBaseUrl + '/ws');
        stompClient = Stomp.over(socket);

        stompClient.debug = function(str) {
            console.log('🔍 STOMP: ' + str);
        };

        stompClient.connect(
            {
                clientId: clientId
            },
            function (frame) {
                setConnected(true);
                console.log('✅ Connected: ' + frame);
                log("--- Соединение установлено, clientId=" + clientId + " ---");

                stompClient.subscribe('/user/topic/trades', function (message) {
                    console.log('📨 MESSAGE ARRIVED:', message);
                    console.log('📨 Headers:', message.headers);
                    console.log('📨 Body:', message.body);
                    log("RECEIVED: " + message.body);
                }, {
                    id: 'sub-trades-' + Math.random()
                });
            },
            function (error) {
                console.error('❌ Connection error:', error);
                log("ERROR: " + error);
                setConnected(false);
            }
        );
    }

    function disconnect() {
        if (stompClient !== null) {
            stompClient.disconnect();
        }
        setConnected(false);
        log("--- Соединение закрыто ---");
    }

    function sendConfig() {
        var destination = document.getElementById('destination').value;
        var jsonConfig = document.getElementById('jsonConfig').value;

        try {
            JSON.parse(jsonConfig);
            stompClient.send(destination, {}, jsonConfig);
            log("SENT to " + destination + ": " + jsonConfig);
        } catch (e) {
            alert("Ошибка в JSON! Проверьте синтаксис.");
        }
    }

    function log(message) {
        var messagesDiv = document.getElementById('messages');
        var p = document.createElement('p');
        p.style.wordWrap = 'break-word';
        p.style.borderBottom = '1px solid #eee';
        p.style.margin = '0';
        p.style.padding = '5px';

        var time = new Date().toLocaleTimeString();
        p.innerText = `[${time}] ${message}`;

        messagesDiv.prepend(p);
    }

    function clearLog() {
        document.getElementById('messages').innerHTML = '';
    }
</script>
```

---

# Что должен делать frontend

Правильная последовательность такая:

```text
1. Открыть WebSocket на /ws.
2. Отправить STOMP CONNECT с clientId.
3. Получить STOMP CONNECTED.
4. Подписаться на /user/topic/trades.
5. Отправить конфиг на /app/config.
6. Получать сообщения.
```

Пример:

```javascript
const socket = new WebSocket('wss://your-host/ws');
const stompClient = Stomp.over(socket);

stompClient.connect(
    {
        clientId: 'client-123'
    },
    function () {
        stompClient.subscribe('/user/topic/trades', function (message) {
            console.log('Received:', message.body);
        });

        stompClient.send('/app/config', {}, JSON.stringify({
            type: 'SetViewConfiguration',
            data: {
                startRow: 0,
                endRow: 1000,
                requestId: 'request-1'
            }
        }));
    },
    function (error) {
        console.error('Connection failed:', error);
    }
);
```

---

# Что проверить в браузере

Попросите фронтендера открыть DevTools → Network → WS и проверить запрос.

Должен быть запрос:

```text
wss://your-host/ws
```

Статус должен быть:

```text
101 Switching Protocols
```

Если видите:

```text
404
```

значит frontend идёт не на тот путь или ingress не маршрутизирует `/ws`.

Если видите:

```text
403
```

часто проблема в `Origin`, Spring Security, Istio policy или авторизации.

Если видите:

```text
400
```

часто проблема в том, что frontend использует SockJS, а backend — native WebSocket, или наоборот.

Если frontend на HTTPS, то WebSocket обязательно должен быть:

```text
wss://...
```

а не:

```text
ws://...
```

Иначе браузер может заблокировать mixed content.

---

# Что проверить в ingress-nginx

Для WebSocket path должен включать `/ws`.

Пример:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: pivot-service-ingress
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-connect-timeout: "60"
spec:
  ingressClassName: nginx
  rules:
    - host: your-host
      http:
        paths:
          - path: /ws
            pathType: Prefix
            backend:
              service:
                name: pivot-service
                port:
                  number: 8080
```

Если frontend ходит на:

```text
wss://your-host/ws
```

то ingress должен прокидывать именно `/ws`.

---

# Что проверить в Istio

Если у вас перед приложением ещё Istio, проверьте, что `VirtualService` тоже маршрутизирует `/ws`.

Например:

```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: pivot-service
spec:
  hosts:
    - your-host
  gateways:
    - your-gateway
  http:
    - match:
        - uri:
            prefix: /ws
      route:
        - destination:
            host: pivot-service
            port:
              number: 8080
      timeout: 0s
```

---

# Самый подозрительный момент в вашей ситуации

Если после открытия debug-страницы в другой вкладке сайт начинает работать, я бы первым делом проверил не backend-код, а **что именно делает debug-страница**.

Возможны два разных сценария.

## Сценарий 1

Вы просто открываете страницу:

```text
https://your-host/websocket/trades
```

и после этого сайт начинает подключаться.

Тогда debug-страница, возможно, создаёт cookie/auth/session. Надо сравнить WebSocket request headers до и после открытия debug-страницы.

Смотрите, появляется ли:

```http
Cookie: JSESSIONID=...
```

или:

```http
Cookie: XSRF-TOKEN=...
```

Если да, проблема в security/session/CSRF.

---

## Сценарий 2

Вы открываете debug-страницу, нажимаете `Connect`, потом `Send Config`, и после этого сайт начинает получать данные.

Тогда возможно, что frontend-сайт сам не отправляет нужный конфиг на:

```text
/app/config
```

У вас сервер начинает обрабатывать клиентский запрос только здесь:

```java
@MessageMapping("/config")
public void handleClientRequest(@Payload JsonNode request, SimpMessageHeaderAccessor headerAccessor) throws SQLException {
    requestProcessDispatcher.dispatchClientRequest(request, headerAccessor);
}
```

То есть если frontend только подключился и подписался, но не отправил конфиг на:

```text
/app/config
```

то backend может ничего ему не отправлять.

Тогда это уже не проблема WebSocket-соединения, а проблема бизнес-протокола:

```text
WebSocket подключился, но frontend не отправил начальный config/clientId.
```

---

# Минимальный чек-лист для вас и фронтендера

Попросите фронтендера дать вам:

1. URL подключения.
2. Использует ли он `WebSocket` или `SockJS`.
3. Network status для `/ws`.
4. Есть ли `101 Switching Protocols`.
5. STOMP frame `CONNECT`.
6. Есть ли в `CONNECT` header `clientId`.
7. Есть ли STOMP frame `CONNECTED`.
8. Подписывается ли он на `/user/topic/trades`.
9. Отправляет ли он сообщение на `/app/config`.

Правильный STOMP-flow должен выглядеть примерно так:

```text
CONNECT
clientId:client-123
accept-version:1.1,1.0
heart-beat:10000,10000

^@
```

Потом сервер:

```text
CONNECTED
version:1.1
heart-beat:10000,10000

^@
```

Потом клиент:

```text
SUBSCRIBE
id:sub-trades
destination:/user/topic/trades

^@
```

Потом клиент:

```text
SEND
destination:/app/config
content-type:application/json

{"type":"SetViewConfiguration","data":{"requestId":"123"}}
^@
```

---

# Итог

У вас REST-ручка:

```text
/websocket/trades
```

не нужна для WebSocket.

Правильный WebSocket endpoint:

```text
/ws
```

Frontend должен подключаться напрямую:

```text
wss://your-host/ws
```

и передавать `ClientId` в STOMP `CONNECT` headers:

```javascript
stompClient.connect(
    { clientId: 'client-123' },
    onConnect,
    onError
);
```

С вашей стороны я бы исправил три вещи:

1. Убрал бы изменение `CONNECT_ACK` в `configureClientOutboundChannel`.
2. Добавил бы `configureClientInboundChannel` и читал `clientId` из STOMP `CONNECT`.
3. Проверил бы, что frontend использует тот же режим, что backend: native WebSocket, а не SockJS.

Тогда никакая debug REST-страница для установки WebSocket-соединения не понадобится.
