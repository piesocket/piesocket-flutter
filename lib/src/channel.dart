import 'dart:convert';

import 'connection.dart';
import 'misc/logger.dart';
import 'misc/piesocket_event.dart';
import 'misc/piesocket_exception.dart';
import 'misc/piesocket_options.dart';
import 'pie_rtc.dart';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:uuid/uuid.dart';
import 'package:http/http.dart' as http;

class Channel {
  static const int NORMAL_CLOSURE_STATUS = 1000;
  late String id;
  late WebSocketChannel ws;
  late String uuid;

  /// Set when this handle rides a shared v4 [Connection] instead of owning
  /// its own socket. `ws` is unused in that mode.
  Connection? hub;

  /// Set when this is a PieRTC (WebRTC) room — see [PieSocket.join]'s
  /// `video`/`audio`/`pieRTC` params. Only meaningful under `version: "4"`;
  /// v3's WebRTC equivalent doesn't exist in this SDK.
  PieRTC? pieRTC;

  /// True for any [Channel.multiplexed] instance, even before [hub] is
  /// attached (a guarded primary/secondary sits with `hub == null` while its
  /// authEndpoint fetch is in flight). Distinguishes "no hub yet" from "owns
  /// its own `ws`" — `ws` is a late field that's simply never initialized on
  /// this path, so falling through to it would throw a
  /// LateInitializationError instead of a clear, catchable exception.
  bool _isMultiplexed = false;

  /// Control-frame params replayed by [Connection] across a reconnect —
  /// only meaningful for a secondary (non-primary) multiplexed channel.
  Map<String, dynamic>? subscribeParams;

  late Map<String, Map<String, Function(PieSocketEvent event)>> _listeners;
  late Logger _logger;
  late PieSocketOptions _options;
  late List _members;
  late bool _shouldReconnect;

  Channel(String roomId, this._options, this._logger) {
    id = roomId;
    _listeners = {};
    uuid = const Uuid().v4();
    _shouldReconnect = false;
    _members = [];

    connect();
  }

  /// A v4 handle sharing [hub]'s socket instead of opening its own — see
  /// [PieSocket.join] under `version: "4"`. The primary channel (the one
  /// [hub] connected with) IS live immediately; secondary channels become
  /// live once their `system::subscribe` control frame is acked.
  Channel.multiplexed(String channelId, this._options, this._logger, this.hub) {
    id = channelId;
    _isMultiplexed = true;
    _listeners = {};
    uuid = const Uuid().v4();
    _shouldReconnect = false;
    _members = [];
  }

  Channel.forTesting(String channelId) {
    id = channelId;
    _listeners = {};
    _logger = Logger(false);
    uuid = const Uuid().v4();
    _shouldReconnect = false;
    _options = PieSocketOptions();
    _members = [];
  }

  Channel.connect(String websocketUrl, bool enableLogs) {
    id = "standalone";
    _listeners = {};
    _logger = Logger(enableLogs);
    uuid = const Uuid().v4();
    _shouldReconnect = false;

    _options = PieSocketOptions();
    _options.setWebSocketEndpoint(websocketUrl);

    connect();
  }

  static String buildUrl(
      String channelId, PieSocketOptions options, String channelUuid,
      {String? jwt}) {
    if (options.getWebSocketEndpoint().isNotEmpty) {
      return options.getWebSocketEndpoint();
    }

    final protocol = options.getSsl() ? 'wss' : 'ws';
    final domain = options.getClusterDomain().isNotEmpty
        ? options.getClusterDomain()
        : '${options.getClusterId()}.piesocket.com';

    String endpoint =
        "$protocol://$domain/v${options.getVersion()}/$channelId?api_key=${options.getApiKey()}&notify_self=${options.getNotifySelf()}&source=fluttersdk&v=1&be=1&presence=${options.getPresence()}";

    if (jwt != null) {
      endpoint = "$endpoint&jwt=$jwt";
    }

    if (options.getUserId().isNotEmpty) {
      endpoint = "$endpoint&user=${options.getUserId()}";
    }

    endpoint = "$endpoint&uuid=$channelUuid";

    return endpoint;
  }

  String buildEndpoint() {
    return buildUrl(id, _options, uuid, jwt: getAuthToken());
  }

  bool isGuarded() {
    if (_options.getForceAuth()) {
      return true;
    }

    return id.startsWith("private-");
  }

  String? getAuthToken() {
    if (_options.getJwt().isNotEmpty) {
      return _options.getJwt();
    }

    if (isGuarded()) {
      if (_options.getAuthEndpoint().isNotEmpty) {
        getAuthTokenFromServer();
        throw PieSocketException(
            "JWT not provided, will fetch from authEndpoint.");
      } else {
        throw PieSocketException(
            "Neither JWT, nor authEndpoint is provided for private channel authentication.");
      }
    }

    return null;
  }

  Future<void> getAuthTokenFromServer() async {
    try {
      String apiURL = _options.getAuthEndpoint();

      Map<String, String> headers = {
        "Content-Type": "application/json",
        "Accept": "application/json",
        ..._options.getAuthHeaders()
      };

      var body = json.encode({"channel_name": id, "connection_uuid": uuid});

      var apiResult = await http.post(
        Uri.parse(apiURL),
        headers: headers,
        body: body,
      );

      var jsonObject = json.decode(apiResult.body) as Map;
      if (jsonObject['auth'] != null) {
        _logger.debug("Auth token fetched, resuming connection");
        _options.setJwt(jsonObject['auth']);
        connect();
      }
    } catch (e) {
      throw PieSocketException(
          "Auth Token Response Parsing Error: ${e.toString()}");
    }
  }

  connect() {
    _logger.debug("Connecting to: $id");

    try {
      String endpoint = buildEndpoint();
      _logger.debug("WebSocket Endpoint: $endpoint");

      ws = WebSocketChannel.connect(Uri.parse(endpoint));

      ws.stream.listen(
          (message) {
            onMessage(message);
          },
          cancelOnError: true,
          onError: (error) {
            onError(error);
          },
          onDone: () {
            onClosing();
          });
    } catch (e) {
      if (e.toString().contains("will fetch from authEndpoint")) {
        _logger.debug("Defer connection: fetching token from authEndpoint");
      } else {
        rethrow;
      }
    }
  }

  void disconnect() {
    _shouldReconnect = false;

    if (hub != null) {
      // A multiplexed secondary channel has no socket of its own — the
      // primary/promotion dance lives in PieSocket.leave(), which only calls
      // disconnect() for non-primary channels.
      final oldHub = hub!;
      oldHub.unsubscribeChannel(id).catchError((_) {});
      oldHub.detachChannel(id);
      // Clear it so any reference to this Channel retained after leave()
      // gets a clear PieSocketException from publish()/send() instead of
      // silently forwarding into a connection it's no longer part of.
      hub = null;
      return;
    }

    if (_isMultiplexed) {
      // hub not attached yet (still resolving auth) — nothing to close.
      return;
    }

    ws.sink.close(NORMAL_CLOSURE_STATUS);
  }

  void reconnect() {
    if (_shouldReconnect) {
      connect();
    }
  }

  String listen(String eventName, Function(PieSocketEvent event) callback) {
    late Map<String, Function(PieSocketEvent event)> callbacks;

    if (_listeners.containsKey(eventName)) {
      callbacks = _listeners[eventName]!;
    } else {
      callbacks = {};
    }

    var listenerId = const Uuid().v4();

    callbacks[listenerId] = callback;
    _listeners[eventName] = callbacks;

    return listenerId;
  }

  void removeListener(String eventName, String listenerId) {
    if (_listeners.containsKey(eventName)) {
      _listeners[eventName]?.remove(listenerId);
    }
  }

  void removeAllListeners(String eventName) {
    if (_listeners.containsKey(eventName)) {
      _listeners.remove(eventName);
    }
  }

  void fireEvent(PieSocketEvent event) {
    _logger.debug("Firing Event: $event");

    if (_listeners.containsKey(event.getEvent())) {
      triggerAllListeners(event.getEvent(), event);
    }

    if (_listeners.containsKey("*")) {
      triggerAllListeners("*", event);
    }
  }

  void triggerAllListeners(String listenerKey, PieSocketEvent event) {
    Map<String, Function(PieSocketEvent event)>? callbacks =
        _listeners[listenerKey];

    if (callbacks != null) {
      for (var k in callbacks.keys) {
        callbacks[k]!(event);
      }
    }
  }

  void publish(PieSocketEvent event) {
    if (hub != null) {
      hub!.send(id, event);
      return;
    }
    if (_isMultiplexed) {
      throw PieSocketException(
          'Channel "$id" is not connected yet — its authEndpoint fetch is still in flight.');
    }
    ws.sink.add(event.toString());
  }

  /// Publish a structured payload directly, without pre-stringifying it into
  /// a [PieSocketEvent] first. Fixes a real footgun in [publish]:
  /// [PieSocketEvent] stores `data`/`meta` as `String`, so a caller who wants
  /// to send a Map is forced to `setData(jsonEncode(myMap))` — but
  /// [PieSocketEvent.toString] then `json.encode`s that already-encoded
  /// string again, double-escaping it on the wire
  /// (`"data":"{\"foo\":1}"` instead of `"data":{"foo":1}`).
  void publishEvent(String eventName, {dynamic data, dynamic meta}) {
    send(json.encode({'event': eventName, 'data': data, 'meta': meta}));
  }

  /// Re-sync this channel's presence roster from the server (v4 only) via
  /// `system::get_members`. Resolves with the refreshed member list; on v3
  /// (no shared connection to ask) resolves with the roster already held.
  Future<List> refreshMembers() {
    if (hub != null) {
      return hub!.requestMembers(id);
    }
    return Future.value(_members);
  }

  void send(String text) {
    if (hub != null) {
      hub!.sendRaw(id, text);
      return;
    }
    if (_isMultiplexed) {
      throw PieSocketException(
          'Channel "$id" is not connected yet — its authEndpoint fetch is still in flight.');
    }
    ws.sink.add(text);
  }

  void onOpen() {
    PieSocketEvent event = PieSocketEvent("system:connected");
    fireEvent(event);

    _shouldReconnect = true;
  }

  void onMessage(String text) {
    if (_listeners.containsKey("system:message")) {
      PieSocketEvent payload = PieSocketEvent("system:message");
      payload.setData(text);
      triggerAllListeners("system:message", payload);
    }

    try {
      var obj = json.decode(
        text,
      );
      if (obj["event"] != null) {
        String eventName = obj["event"];
        if (eventName == "system:boot") {
          onOpen();
        } else {
          PieSocketEvent event = PieSocketEvent(eventName);

          if (obj["data"] != null) {
            String eventData;

            if (obj['data'].runtimeType == String) {
              eventData = obj['data'];
            } else {
              eventData = jsonEncode(obj['data']);
            }

            event.setData(eventData);
          }
          if (obj["meta"] != null) {
            String eventMeta;

            if (obj['meta'].runtimeType == String) {
              eventMeta = obj['meta'];
            } else {
              eventMeta = jsonEncode(obj['meta']);
            }
            event.setMeta(eventMeta);
          }

          // Trigger listeners
          handleSystemEvents(event);
          _handlePieRTCEvent(eventName, obj["data"]);
          fireEvent(event);
        }
      }
      if (obj["error"] != null) {
        _shouldReconnect = false;
        PieSocketEvent event = PieSocketEvent("system:error");
        event.setData(obj["error"]);
        fireEvent(event);
      }
    } catch (e) {
      //Ignore error
      _logger.debug("Non-json message received: $text");
    }
  }

  void handleSystemEvents(PieSocketEvent event) {
    // v4 delivers presence as deltas: member_joined / member_left carry only
    // the member that changed, and the full roster arrives once as
    // member_list (on join or in response to system::get_members /
    // refreshMembers()). v4's system events are double-colon (`system::x`)
    // end-to-end; v3's stay single-colon.
    final deltaPresence = _options.getVersion() == "4";
    final memberListEvent =
        deltaPresence ? "system::member_list" : "system:member_list";
    final memberJoinedEvent =
        deltaPresence ? "system::member_joined" : "system:member_joined";
    final memberLeftEvent =
        deltaPresence ? "system::member_left" : "system:member_left";

    try {
      if (event.getEvent() == memberListEvent) {
        var data = json.decode(event.getData());
        _members = (data["members"] as List?) ?? [];
      } else if (event.getEvent() == memberJoinedEvent) {
        var data = json.decode(event.getData());
        if (deltaPresence) {
          _addMember(data["member"]);
        } else {
          _members = (data["members"] as List?) ?? [];
        }
      } else if (event.getEvent() == memberLeftEvent) {
        var data = json.decode(event.getData());
        if (deltaPresence) {
          _removeMember(data["member"]);
        } else {
          _members = (data["members"] as List?) ?? [];
        }
        final member = data["member"];
        if (pieRTC != null && member is Map && member["uuid"] != null) {
          pieRTC!.removeParticipant(member["uuid"] as String);
        }
      }
    } catch (e) {
      throw PieSocketException(e.toString());
    }
  }

  /// Routes PieRTC's `rtc::*` signalling frames — its own namespace, kept
  /// separate from both v3's `system:` and v4's `system::` events so it's
  /// never mistaken for a control frame. No-op when [pieRTC] isn't attached
  /// (a plain subscriber sharing a channel name with a PieRTC room still
  /// receives its broadcasts and must not crash on them).
  void _handlePieRTCEvent(String eventName, dynamic data) {
    if (pieRTC == null || data is! Map) return;

    final from = data['from'];
    final to = data['to'];

    if (eventName == 'rtc::broadcaster' && from != uuid) {
      pieRTC!.requestOfferFromPeer();
    } else if (eventName == 'rtc::stopped_screen' && from != uuid) {
      pieRTC!.onRemoteScreenStopped(from as String, data['streamId'] as String);
    } else if (eventName == 'rtc::watcher' && from != uuid) {
      pieRTC!.shareVideo(data);
    } else if (eventName == 'rtc::request' && from != uuid) {
      pieRTC!.shareVideo(data);
    } else if (eventName == 'rtc::candidate' && to == uuid) {
      pieRTC!.addIceCandidate(data);
    } else if (eventName == 'rtc::offer' && to == uuid) {
      pieRTC!.createAnswer(data);
    } else if (eventName == 'rtc::answer' && to == uuid) {
      pieRTC!.handleAnswer(data);
    }
  }

  String _memberKey(dynamic member) {
    if (member is Map) {
      return member['uuid'] != null
          ? 'uuid:${member['uuid']}'
          : 'obj:${json.encode(member)}';
    }
    return 'val:$member';
  }

  void _addMember(dynamic member) {
    if (member == null) return;
    final key = _memberKey(member);
    if (!_members.any((m) => _memberKey(m) == key)) {
      _members.add(member);
    }
  }

  void _removeMember(dynamic member) {
    if (member == null) return;
    final key = _memberKey(member);
    _members.removeWhere((m) => _memberKey(m) == key);
  }

  void onClosing() {
    PieSocketEvent event = PieSocketEvent("system:closed");
    fireEvent(event);

    reconnect();
  }

  void onError(dynamic error) {
    PieSocketEvent event = PieSocketEvent("system:error");
    event.setData(error.toString());
    fireEvent(event);

    onClosing();
  }

  dynamic getMemberByUUID(String uuid) {
    for (var member in _members) {
      try {
        if (member["uuid"] == uuid) {
          return member;
        }
      } catch (e) {
        //Ignore errors, member can be a string and JSONException is possible
      }
    }

    return null;
  }

  dynamic getCurrentMember() {
    return getMemberByUUID(uuid);
  }

  List getAllMembers() {
    return _members;
  }
}
