import 'dart:convert';

import 'misc/logger.dart';
import 'misc/piesocket_event.dart';
import 'misc/piesocket_exception.dart';
import 'misc/piesocket_options.dart';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:uuid/uuid.dart';
import 'package:http/http.dart' as http;

class Channel {
  static const int NORMAL_CLOSURE_STATUS = 1000;
  late String id;
  late WebSocketChannel ws;
  late String uuid;

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

    connect();
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

  String buildEndpoint() {
    if (_options.getWebSocketEndpoint().isNotEmpty) {
      return _options.getWebSocketEndpoint();
    }

    String endpoint =
        "wss://${_options.getClusterId()}.piesocket.com/v${_options.getVersion()}/$id?api_key=${_options.getApiKey()}&notify_self=${_options.getNotifySelf()}&source=fluttersdk&v=1&be=1&presence=${_options.getPresence()}";

    String? jwt = getAuthToken();
    if (jwt != null) {
      endpoint = "$endpoint&jwt=$jwt";
    }

    if (_options.getUserId().isNotEmpty) {
      endpoint = "$endpoint&user=${_options.getUserId()}";
    }

    //Add UUID
    endpoint = "$endpoint&uuid=$uuid";

    return endpoint;
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
    ws.sink.add(event.toString());
  }

  void send(String text) {
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
    try {
      //Update members list
      if (event.getEvent() == "system:member_list" ||
          event.getEvent() == "system:member_joined" ||
          event.getEvent() == "system:member_left") {
        var data = json.decode(event.getData());
        _members = data["members"] as List;
      }
    } catch (e) {
      throw PieSocketException(e.toString());
    }
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
