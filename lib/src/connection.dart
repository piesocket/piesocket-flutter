import 'dart:async';
import 'dart:convert';

import 'channel.dart';
import 'misc/logger.dart';
import 'misc/piesocket_event.dart';
import 'misc/piesocket_exception.dart';
import 'misc/piesocket_options.dart';

import 'package:web_socket_channel/web_socket_channel.dart';

const int _controlTimeoutMs = 10000;

/// A single WebSocket shared by many [Channel] handles (PieSocket v4).
///
/// The channel named at connect time is the "primary" — its lifecycle is the
/// socket's lifecycle. Every other channel is subscribed with a
/// `system::subscribe` control frame and rides the same socket; outbound
/// frames for it are tagged with `system::channel`, and inbound frames are
/// routed back to it by the `system::channel` / `data.channel` the server
/// stamps on them.
///
/// All v4 control/system events are `system::x` (double colon) — this is a
/// separate, untouched convention from v3's single-colon `system:` events
/// that [Channel] still speaks natively when not attached to a hub.
class Connection {
  String primaryChannelId;
  final PieSocketOptions options;
  final Logger logger;

  final Map<String, Channel> channels = {};
  final Map<String, _PendingControl> _pending = {};
  final Map<String, List<Completer<List>>> _memberRequests = {};

  late String _primaryUuid;
  String? _primaryJwt;
  late WebSocketChannel _ws;
  StreamSubscription? _wsSubscription;
  bool connected = false;
  bool shouldReconnect = false;
  bool _migrating = false;
  bool _openedOnce = false;

  /// Set by PieSocket to learn when the primary channel's socket actually
  /// opens (or fails) — join() itself stays synchronous, this is purely for
  /// callers who want to know when the shared connection is live.
  void Function()? onPrimaryConnected;
  void Function(dynamic error)? onPrimaryError;

  /// Overridable for tests — avoids needing a real socket to test routing.
  void Function(String data)? sendOverride;

  /// Overridable for tests — binary counterpart of [sendOverride].
  void Function(List<int> bytes)? sendBinaryOverride;

  /// Opens the shared socket with [primaryChannelId] as primary. [uuid] and
  /// [jwt] (if the channel is guarded) are baked into the connect URL the
  /// same way a standalone [Channel] builds its own. [primaryChannel] is
  /// attached before the socket connects — `_connect()` fires `onOpen()`
  /// synchronously (Dart's `WebSocketChannel` has no async "open" event to
  /// wait for), which looks up `channels[primaryChannelId]` to fire
  /// `system:connected`; attaching it here instead of leaving the caller to
  /// call `attachChannel()` afterward means that lookup is never too late.
  Connection(this.primaryChannelId, this.options, this.logger, String uuid,
      Channel primaryChannel,
      {String? jwt}) {
    _primaryUuid = uuid;
    _primaryJwt = jwt;
    channels[primaryChannelId] = primaryChannel;
    _connect(Channel.buildUrl(primaryChannelId, options, uuid, jwt: jwt));
  }

  Connection.forTesting(
      this.primaryChannelId, this.options, this.logger, this.sendOverride);

  bool isPrimary(String channelId) => channelId == primaryChannelId;

  void attachChannel(String channelId, Channel channel) {
    channels[channelId] = channel;
  }

  void detachChannel(String channelId) {
    channels.remove(channelId);
    _settleMemberRequests(channelId, false,
        PieSocketEvent('system::error')..setData('Channel detached'));
  }

  // ===== Outbound =====

  void _rawSend(String data) {
    if (sendOverride != null) {
      sendOverride!(data);
      return;
    }
    _ws.sink.add(data);
  }

  void _rawSendBinary(List<int> bytes) {
    if (sendBinaryOverride != null) {
      sendBinaryOverride!(bytes);
      return;
    }
    _ws.sink.add(bytes);
  }

  /// Send a raw binary frame on the shared socket — see [Channel.sendBinary].
  /// Only valid for the primary channel: raw bytes carry no `system::channel`
  /// tag, so a secondary channel's frame can't be attributed server-side.
  void sendBinary(String channelId, List<int> bytes) {
    if (!isPrimary(channelId)) {
      throw PieSocketException(
          'Binary frames are only supported on the primary channel, not "$channelId".');
    }
    _rawSendBinary(bytes);
  }

  void sendControl(String eventName, Map<String, dynamic> data) {
    try {
      _rawSend(json.encode({'event': eventName, 'data': data}));
    } catch (e) {
      logger.debug('PieSocket: control frame send failed: $e');
    }
  }

  /// Send an application frame on behalf of [channelId]. Secondary channels
  /// get a `system::channel` tag so the receiving multiplexed client (and the
  /// server) can attribute the frame to the right subscription.
  void send(String channelId, PieSocketEvent event) {
    final Map<String, dynamic> payload = {
      'event': event.getEvent(),
      'data': event.getData(),
      'meta': event.getMeta(),
    };

    if (!isPrimary(channelId)) {
      payload['system::channel'] = channelId;
    }

    _rawSend(json.encode(payload));
  }

  /// Like [send], but for an already-serialised (or non-JSON) payload —
  /// used by [Channel.send]. Tries to parse it as JSON to tag
  /// `system::channel` on a secondary channel; falls back to sending it
  /// verbatim if it isn't JSON.
  void sendRaw(String channelId, String text) {
    if (!isPrimary(channelId)) {
      try {
        final obj = json.decode(text);
        if (obj is Map) {
          obj['system::channel'] = channelId;
          _rawSend(json.encode(obj));
          return;
        }
      } catch (e) {
        // Not JSON — fall through and send verbatim.
      }
    }

    _rawSend(text);
  }

  // ===== Subscription control =====

  Future<void> subscribeChannel(String channelId, Map<String, dynamic> params) {
    final completer = Completer<void>();
    final timer = Timer(const Duration(milliseconds: _controlTimeoutMs), () {
      if (_pending.remove(channelId) != null && !completer.isCompleted) {
        completer.completeError('system::subscribe timed out for "$channelId"');
      }
    });

    _pending[channelId] = _PendingControl(completer, timer, params);

    if (connected) {
      sendControl('system::subscribe', params);
    }
    // Otherwise onOpen() replays every pending subscribe.

    return completer.future;
  }

  Future<void> unsubscribeChannel(String channelId) {
    if (isPrimary(channelId)) {
      return Future.error('Cannot unsubscribe the primary channel directly');
    }

    final completer = Completer<void>();
    final timer = Timer(const Duration(milliseconds: _controlTimeoutMs), () {
      if (_pending.remove(channelId) != null && !completer.isCompleted) {
        completer.complete();
      }
    });

    _pending[channelId] = _PendingControl(completer, timer, null);
    sendControl('system::unsubscribe', {'channel': channelId});

    return completer.future;
  }

  Future<List> requestMembers(String channelId) {
    final completer = Completer<List>();
    _memberRequests.putIfAbsent(channelId, () => []).add(completer);

    // Unlike subscribeChannel/unsubscribeChannel, a dropped connection while
    // this is in flight is only caught by onClose()/onError() rejecting
    // whatever's left in _memberRequests — this timeout is the backstop for
    // a reply that never arrives at all (server never responds, frame lost).
    final timer = Timer(const Duration(milliseconds: _controlTimeoutMs), () {
      if (!completer.isCompleted) {
        _memberRequests[channelId]?.remove(completer);
        completer
            .completeError('system::get_members timed out for "$channelId"');
      }
    });
    completer.future.whenComplete(() => timer.cancel());

    sendControl('system::get_members', {'channel': channelId});
    return completer.future;
  }

  /// Re-open the socket with [newPrimaryId] as the primary channel, keeping
  /// every other subscription. Frames in flight during the swap may be missed.
  void migratePrimary(String newPrimaryId, String endpoint,
      {String? newUuid, String? newJwt}) {
    _migrating = true;

    // Cancel the old socket's listener first — otherwise its onDone/onError
    // still fires (asynchronously, after this method returns) against the
    // new socket's state, wrongly resetting `connected` and triggering a
    // second unwanted reconnect. `_migrating` alone doesn't cover this: it's
    // back to false by the time that late callback arrives.
    try {
      _wsSubscription?.cancel();
    } catch (e) {
      // ignore
    }
    try {
      _ws.sink.close();
    } catch (e) {
      // ignore
    }

    primaryChannelId = newPrimaryId;
    channels[newPrimaryId]?.subscribeParams = null;
    if (newUuid != null) _primaryUuid = newUuid;
    _primaryJwt = newJwt;

    connected = false;
    _connect(endpoint);
    _migrating = false;
  }

  void close() {
    shouldReconnect = false;
    try {
      _ws.sink.close();
    } catch (e) {
      // ignore
    }
  }

  // ===== Socket events =====

  void _connect(String endpoint) {
    _ws = WebSocketChannel.connect(Uri.parse(endpoint));

    // cancelOnError: false — the only reconnect logic lives in onClose(),
    // fired via onDone. If this subscription auto-cancelled on the first
    // error (cancelOnError: true), onDone would never fire afterward and a
    // single transport error would kill the shared socket permanently with
    // no recovery. onError() closes the sink itself, which still triggers a
    // natural onDone once the stream actually finishes.
    _wsSubscription = _ws.stream.listen(
      (message) => onMessage(message),
      cancelOnError: false,
      onError: (error) => onError(error),
      onDone: () => onClose(),
    );

    // WebSocketChannel has no synchronous "open" callback in Dart (nor a
    // meaningful async one on the web_socket_channel version this depends
    // on — `.ready` is a no-op `Future.value()` before 3.x) — treat the
    // socket as open once construction succeeds, the same as Channel's own
    // connect(); errors surface via onError/onDone instead. Deferred a
    // microtask, same reasoning as _fireErrorNextMicrotask: this runs from
    // inside PieSocket.join() (via the Connection constructor), before
    // join() has returned the Channel to its caller — firing inline would
    // mean a `channel.listen('system:connected', ...)` right after join()
    // returns could never catch it.
    scheduleMicrotask(onOpen);
  }

  void onOpen() {
    connected = true;
    shouldReconnect = true;

    // Replay every secondary subscription (reconnect / primary migration).
    channels.forEach((channelId, channel) {
      if (isPrimary(channelId)) return;
      final params = channel.subscribeParams;
      if (params != null) {
        sendControl('system::subscribe', params);
      }
    });

    // Replay subscribes that were still in flight across a reconnect.
    _pending.forEach((channelId, entry) {
      if (entry.params != null) {
        sendControl('system::subscribe', entry.params!);
      }
    });

    if (!_openedOnce) {
      _openedOnce = true;
      onPrimaryConnected?.call();
    }

    channels[primaryChannelId]?.onOpen();
  }

  void onMessage(dynamic message) {
    if (message is! String) {
      // Binary WS frames aren't used by v4 (server always wraps binary as a
      // system::binary JSON event) — ignore anything else defensively.
      return;
    }

    Map<String, dynamic>? obj;
    try {
      obj = json.decode(message) as Map<String, dynamic>;
    } catch (e) {
      channels[primaryChannelId]?.onMessage(message);
      return;
    }

    final event = obj['event'];

    if (event == 'system::subscribe_success' ||
        event == 'system::subscribe_error' ||
        event == 'system::unsubscribe_success' ||
        event == 'system::unsubscribe_error') {
      _settleControl(event as String, obj);
      return;
    }

    if (event == 'system::member_list_error') {
      final data = obj['data'] as Map<String, dynamic>?;
      final channelId = (data?['channel'] as String?) ?? primaryChannelId;
      _settleMemberRequests(
          channelId,
          false,
          PieSocketEvent('system::member_list_error')
            ..setData(
                (data?['error'] as String?) ?? 'Could not fetch members'));
      return;
    }

    final channelId = (obj['system::channel'] as String?) ??
        ((obj['data'] is Map) ? (obj['data']['channel'] as String?) : null) ??
        primaryChannelId;
    final channel = channels[channelId] ?? channels[primaryChannelId];
    if (channel == null) return;

    channel.onMessage(message);

    // Only settle under `channelId` if that's genuinely the channel this
    // frame resolved to — if it fell back to the primary because `channelId`
    // is no longer in `channels` (e.g. a stale get_members reply racing a
    // detach), reporting the primary's roster under the original id would
    // hand the caller the wrong channel's members.
    if (event == 'system::member_list' && channels[channelId] == channel) {
      _settleMemberRequestsWithMembers(channelId, channel.getAllMembers());
    }
  }

  void onError(dynamic error) {
    logger.debug('PieSocket: connection error: $error');

    if (!connected) {
      onPrimaryError?.call(error);
    }

    channels.forEach((_, channel) {
      final event = PieSocketEvent('system:error')..setData(error.toString());
      channel.fireEvent(event);
    });

    try {
      _ws.sink.close();
    } catch (e) {
      // ignore
    }
  }

  void onClose() {
    connected = false;

    channels.forEach((_, channel) {
      channel.fireEvent(PieSocketEvent('system:closed'));
    });

    if (shouldReconnect && !_migrating) {
      logger.debug('PieSocket: reconnecting multiplexed connection');
      _connect(Channel.buildUrl(primaryChannelId, options, _primaryUuid,
          jwt: _primaryJwt));
    }
  }

  // ===== Internals =====

  void _settleControl(String event, Map<String, dynamic> message) {
    final data = message['data'] as Map<String, dynamic>?;
    final channelId = data?['channel'] as String?;
    if (channelId == null) return;

    final entry = _pending.remove(channelId);
    if (entry == null) return;
    entry.timer.cancel();

    if (event.endsWith('_success')) {
      if (!entry.completer.isCompleted) entry.completer.complete();
    } else {
      if (!entry.completer.isCompleted) {
        entry.completer.completeError((data?['error'] as String?) ?? event);
      }
    }
  }

  void _settleMemberRequests(
      String channelId, bool resolve, PieSocketEvent errorEvent) {
    final list = _memberRequests.remove(channelId);
    if (list == null) return;
    for (final completer in list) {
      if (!completer.isCompleted) {
        completer.completeError(errorEvent.getData());
      }
    }
  }

  void _settleMemberRequestsWithMembers(String channelId, List members) {
    final list = _memberRequests.remove(channelId);
    if (list == null) return;
    for (final completer in list) {
      if (!completer.isCompleted) completer.complete(members);
    }
  }
}

class _PendingControl {
  final Completer completer;
  final Timer timer;
  final Map<String, dynamic>? params;

  _PendingControl(this.completer, this.timer, this.params);
}
