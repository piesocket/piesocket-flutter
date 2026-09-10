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
  event whose `data` is a base64 string — decode it with `base64Decode`. To
  send, call `channel.sendBinary(bytes)` — a raw binary frame the server
  re-wraps as `system::binary` for every other client (JS peers included).
  Primary channel only; a secondary channel's `sendBinary` throws.
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

### PieRTC — WebRTC video/audio rooms (v4 only)

PieRTC is programmable WebRTC over v4 — the Flutter counterpart to
piesocket-js's `PieRTC`. There's no v3 equivalent in this SDK. It depends on
[`flutter_webrtc`](https://pub.dev/packages/flutter_webrtc) (already a
dependency of this package) — your app still needs to add that package's own
camera/microphone permission entries to its `AndroidManifest.xml`/
`Info.plist`; this package has no platform folders of its own to put them in.

```dart
options.setVersion("4");
PieSocket piesocket = PieSocket(options);

Channel room = piesocket.join(
  "video-room",
  video: true,
  cameraFacing: 'user', // 'user' (front, default) or 'environment' (rear)
  onLocalVideo: (stream, pieRTC) { /* attach to a renderer */ },
  onParticipantJoined: (uuid, stream) { /* attach remote stream */ },
  onParticipantLeft: (uuid) { /* remove remote stream */ },
);

// Flip the camera on the live call (no renegotiation):
await room.pieRTC?.switchCamera(); // -> room.pieRTC.isFrontCamera
```

- Pass `video: true`, `audio: true`, or `pieRTC: true` to `join()` to mark a
  room as PieRTC — `room.pieRTC` is attached once the room's connection
  resolves (may be after `join()` already returned, same as everything else
  under v4).
- Signalling uses its own `rtc::` namespace (`rtc::offer`, `rtc::answer`,
  `rtc::candidate`, `rtc::renegotiate`, etc.) — a plain PieSocket relay, no
  server-side special-casing, so a Flutter and a JS/web client can share the
  same room.
- Negotiation is **collision-free**: for each peer pair the client with the
  larger uuid is the sole offerer and the other side only answers (it sends
  `rtc::renegotiate` to ask for a fresh offer when it adds a track). This is
  what makes a symmetric 1:1 call — both sides sending audio + video — work
  without SDP glare.
- `onParticipantJoined` fires once per remote stream, for **audio-only** peers
  as well as video ones.
- **Camera:** `cameraFacing` on `join()` picks the starting lens (`'user'`
  front / `'environment'` rear; default front). `room.pieRTC.switchCamera()`
  flips it live and returns the new `room.pieRTC.isFrontCamera`.
- **`room.pieRTC.shareScreen()`** renegotiates a screen track onto every peer
  (alongside the camera); **`stopScreenShare()`** removes it. Both fire
  `onScreenSharingStopped` (with this client's own uuid) and publish
  `rtc::stopped_screen`; the SDK also stops if the user ends the share from
  the OS UI. Zero-config on web, desktop, macOS and iOS (iOS uses in-app
  ReplayKit capture). **Android** additionally needs the app to run a
  foreground service of type `mediaProjection` while sharing — the simplest
  way is the [`flutter_background`](https://pub.dev/packages/flutter_background)
  package (`FlutterBackground.enableBackgroundExecution()` before
  `shareScreen()`), which ships the `<service>` its manifest needs.

### PieCall — native incoming calls (CallKit / PushKit / full-screen intent)

`PieCall` turns PieRTC + call signalling + `flutter_callkit_incoming` into a
single object. It shows the native incoming-call UI, rings, wakes the screen,
answers from the lock screen, and — with a push — does all of that when the app
is force-quit.

```dart
final call = PieCall(
  socket: () => piesocket,            // your PieSocket instance (nullable ok)
  selfUserId: () => myUserId,
  config: const PieCallConfig(appName: 'MyApp'),
)
  ..onEnsureConnected = () async { if (!realtime.connected) await realtime.reconnect(); }
  ..onAccept  = (callId) async {
      final r = await api.post('calls/$callId/accept');
      return r['status'] != 'answered_elsewhere';   // false ⇒ another device won, stand down
    }
  ..onDecline = (callId) => api.post('calls/$callId/decline')
  ..onHangUp  = (callId, reason) => api.post('calls/$callId/${reason == 'missed' ? 'timeout' : 'end'}');

// feed it the events you already receive on private-user-<id>
socketChannel.listen('call_invite', (e) => call.handleSignal('call_invite', e.data));

// outgoing
final r = await api.post('calls', {'to_id': peerId, 'media': 'video'});
call.startOutgoing(invite: PieCallInvite.fromMap(r['call']));

// drive your UI
call.updates.listen((s) { /* s.phase, s.invite, s.muted, … */ });
```

**Push wake-up.** Your server sends a data payload on `call_invite` /
`call_cancel` (see the schema in `PieCallPush`). In your FCM background handler:

```dart
@pragma('vm:entry-point')
Future<void> _bg(RemoteMessage m) async {
  if (PieCallPush.isCallPush(m.data)) {
    await Firebase.initializeApp();
    await PieCallPush.handleData(m.data, appName: 'MyApp');
  }
}
```

Register the iOS VoIP token with your backend:
`final token = await PieCall.voipToken();` (and re-register on
`call.voipTokenChanges`).

**iOS setup** (real device only):

- `Info.plist` → `UIBackgroundModes` must include `voip` and `remote-notification`.
- Xcode capabilities: **Push Notifications** + **Background Modes → Voice over IP**.
- `AppDelegate.swift` — implement PushKit + `CallkitIncomingAppDelegate` and
  forward the VoIP push to the plugin **synchronously** (or iOS kills the app):

```swift
import PushKit
import CallKit
import flutter_callkit_incoming

@main
@objc class AppDelegate: FlutterAppDelegate, PKPushRegistryDelegate, CallkitIncomingAppDelegate {
  override func application(_ application: UIApplication,
      didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    let registry = PKPushRegistry(queue: .main)
    registry.delegate = self
    registry.desiredPushTypes = [.voIP]
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
  func pushRegistry(_ r: PKPushRegistry, didUpdate c: PKPushCredentials, for t: PKPushType) {
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.setDevicePushTokenVoIP(
      c.token.map { String(format: "%02x", $0) }.joined())
  }
  func pushRegistry(_ r: PKPushRegistry, didInvalidatePushTokenFor t: PKPushType) {
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.setDevicePushTokenVoIP("")
  }
  func pushRegistry(_ r: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
      for type: PKPushType, completion: @escaping () -> Void) {
    guard type == .voIP else { return }
    let p = payload.dictionaryPayload
    let data = flutter_callkit_incoming.Data(
      id: p["id"] as? String ?? "",
      nameCaller: p["nameCaller"] as? String ?? "",
      handle: p["handle"] as? String ?? "",
      type: (p["isVideo"] as? Bool ?? false) ? 1 : 0)
    data.extra = p as NSDictionary
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.showCallkitIncoming(data, fromPushKit: true) { completion() }
  }
  // onAccept/onDecline/onEnd/onTimeOut: just call action.fulfill() — the Dart side hits your REST API.
}
```

**Android setup:**

- `AndroidManifest.xml`: add `POST_NOTIFICATIONS`, `USE_FULL_SCREEN_INTENT`,
  `WAKE_LOCK`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MICROPHONE`; keep
  `<application android:name="${applicationName}">`.
- `MainActivity` must extend `FlutterFragmentActivity`.
- `app/build.gradle(.kts)`:
  `manifestPlaceholders["applicationName"] = "<pkg>.MainApplication"` and a
  `MainApplication` that calls
  `FlutterCallkitIncomingPlugin.registerEventCallback(...)`.
- `proguard-rules.pro`: `-keep class com.hiennv.flutter_callkit_incoming.** { *; }`.
- Java 17.

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