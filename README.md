# PieSocket Realtime Flutter Client

PieSocket SDK for Flutter written in Dart.


## Installation
Add PieSocket into your project.
```
flutter pub add piesocket_channels
```

## Usage

Import the library
```dart
import 'package:piesocket_channels/channels.dart';
```

### Stand-alone Usage
Create a Channel instance as shown below.
```dart
Chanel channel = Channel.connect("wss://example.com", true)

channel.listen("system:message", (PieSocketEvent event) {
    log("WebSocket message arrived!");
    print(event.toString());
});
```

### PieSocket's managed WebSocket server
Use following code to create a Channel with PieSocket's managed WebSocket servers.

Get your API key and Cluster ID here: [Get API Key](https://www.piesocket.com/app/v4/register)

```dart
PieSocketOptions options = PieSocketOptions();
options.setClusterId("demo");
options.setApiKey("VCXCEuvhGcBDP7XhiJJUDvR1e1D3eiVjgZ9VRiaV");

PieSocket piesocket = PieSocket(options);
Channel channel = piesocket.join("chat-room");
```

### v4 — multi-channel over one connection

Set `version: "4"` to share a **single** WebSocket across every `join()`
call. `join()` still returns a `Channel` synchronously, same as v3 — the
multiplexing happens in the background:

```dart
PieSocketOptions options = PieSocketOptions();
options.setClusterId("demo");
options.setApiKey("VCXCEuvhGcBDP7XhiJJUDvR1e1D3eiVjgZ9VRiaV");
options.setVersion("4");

PieSocket piesocket = PieSocket(options);
Channel chat = piesocket.join("chat-room");     // opens the socket
Channel alerts = piesocket.join("alerts");      // rides the same socket

chat.listen("message", (event) { /* ... */ });
alerts.publishEvent("ping", data: {"at": DateTime.now().toIso8601String()});
```

Notes for v4:

- **`join()` stays synchronous** even for a multiplexed channel — the
  `system::subscribe` control frame is sent in the background. Listen for
  `system:connected` (primary channel) the same way you would under v3. A
  secondary channel's subscribe failing (e.g. `system::subscribe_error`) is
  not delivered to the channel's own listeners — it's only logged — matching
  how the JS SDK handles this same case.
- **Presence is delta-based.** The full roster arrives once; after that
  `Channel`'s member list is kept in sync from join/leave deltas. Call
  `channel.refreshMembers()` to re-sync from the server on demand.
- **All v4 system events are double-colon** (`system::member_joined`,
  `system::binary`, etc.), unlike v3's single-colon `system:` events.
- **Binary needs no opt-in.** Any binary frame arrives as a `system::binary`
  event whose `data` is a base64 string — decode it with `base64Decode`.
- **`publishEvent(event, {data, meta})`** sends a structured payload (a Map,
  List, or primitive) directly, without needing to pre-`jsonEncode` it into a
  `PieSocketEvent` first — use this instead of `publish(PieSocketEvent)` for
  anything beyond a plain string, to avoid double-encoding it on the wire.
- **`notifySelf` is connection-wide, not per-channel** — if the first `join()`
  call is the one that opens the shared socket, every other channel
  multiplexed onto it also gets that socket's `notifySelf` setting.
- **Unsubscribing the connect-time channel** promotes another joined channel
  to keep the connection alive; a few in-flight frames may be missed during
  the swap.
- **Guarded channels** (`private-` prefix, or `forceAuth: true`) resolve
  their JWT from `authEndpoint` the same as v3, without `join()` waiting on
  the fetch — a `join()` for another room that races in while that fetch is
  still in flight attaches once it resolves, rather than opening a second
  shared connection.

[PieSocket](https://piehost.com/piesocket) is scalable WebSocket API service with following features:
  - Authentication
  - Private Channels
  - Presence Channels
  - Publish messages with REST API
  - Auto-scalability
  - Webhooks
  - Analytics
  - Authentication
  - Upto 60% cost savings

We highly recommend using PieSocket over self hosted WebSocket servers for production applications.

## Events
`system:connected` is the event fired when WebSocket connection is ready, get a full list system messages here: [PieSocket System Messages](https://www.piesocket.com/docs/3.0/events#system-events)


## Documentation
For usage examples and more information, refer to: [Official SDK docs](https://www.piesocket.com/docs/3.0/flutter-websockets)