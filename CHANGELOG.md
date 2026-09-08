## 7.0.0
Version realigned to match the other PieSocket client SDKs (piesocket-js et al.);
this is 2.4.0's feature set, renumbered — no breaking API changes from 2.3.0.

Screen sharing: `pieRTC.shareScreen()` now renegotiates the screen track onto
every peer (alongside the camera) and `pieRTC.stopScreenShare()` removes it
again; both fire `onScreenSharingStopped` with this client's own uuid and
publish `rtc::stopped_screen`, and the SDK also stops automatically when the
user ends the share from the OS UI. Zero-config on web, desktop, macOS and
iOS (iOS uses in-app ReplayKit capture); Android additionally needs the app
to run a `mediaProjection` foreground service while sharing — see the README.

Add `Channel.sendBinary(List<int> bytes)` — emits a raw binary WebSocket
frame on the channel's primary connection. The server wraps any inbound
binary frame as a `system::binary` event (base64 `data`) before relaying it,
so a browser/JS peer receives it exactly as it would a binary frame from
another JS client. Only supported on the primary channel — raw bytes carry
no `system::channel` tag, so a secondary channel's frame can't be attributed
server-side; sending on a secondary throws `PieSocketException`. Receiving
binary already worked (any `system::binary` event's `data` is a base64
string); this closes the send side.

## 2.3.0
Add PieRTC — programmable WebRTC video/audio rooms over v4, the Flutter
counterpart to piesocket-js's `PieRTC` (there's no v3 equivalent in this
SDK). Pass `video: true`, `audio: true`, or `pieRTC: true` to `join()` to
mark a room as PieRTC; `room.pieRTC` is attached once the room's connection
resolves. Signalling rides its own `rtc::` namespace — a plain PieSocket
relay, so it interoperates with the JS SDK's rooms. Built on
`flutter_webrtc` (new dependency); your app still owns the camera/mic
permission entries in its own `AndroidManifest.xml`/`Info.plist`, same as
any other `flutter_webrtc` consumer.

## 2.2.0
Add v4 protocol support: set `version: "4"` to share a single WebSocket
across every `join()` call, with delta-based presence and `system::binary`
framing (see README). `join()` stays synchronous, matching v3 — including
for a guarded (`private-`/`forceAuth`) room, whose JWT is resolved from
`authEndpoint` in the background (new `AuthResolver`) rather than blocking
`join()`; a concurrent `join()` racing in during that fetch attaches once
it resolves instead of opening a second primary connection.

Also adds `Channel.publishEvent(event, {data, meta})`, which sends a
structured payload directly instead of requiring it to be pre-`jsonEncode`d
into a `PieSocketEvent` first — fixes a double-encoding footgun in
`publish(PieSocketEvent)` for anyone sending a Map/List. `PieSocketEvent`
itself is unchanged.

Fixes found in review, before this ever shipped: primary migration
(promoting a channel after `leave()`) no longer leaves the old socket's
listener attached, which could otherwise fire a stray close/reconnect after
the new one was already up; a `join()` whose primary attempt fails while
another `join()` is queued behind it now retries instead of leaving that
channel permanently unattached; `leave()` failing to promote a new primary
now tears the shared connection down cleanly instead of leaving it in a
half-detached state; calling `publish`/`send`/`disconnect` on a channel
still waiting on its authEndpoint fetch now throws a clear
`PieSocketException` instead of a `LateInitializationError`; and a
malformed (non-delta) `system:member_joined`/`member_left` frame under v3
no longer crashes on a null cast.

## 2.1.0
Add support for clusterDomain and ssl options.

## 1.1.0
Bump http version to support v1.2.2

## 1.0.1
Moves example into private directory, no functional changes.

## 1.0.0
Official Client SDK for PieSocket Channels is now available for flutter.
This package can be used as a Standalonee WebSocket client too.