import 'dart:async';
import 'dart:collection';

import 'auth_resolver.dart';
import 'channel.dart';
import 'connection.dart';
import 'misc/logger.dart';
import 'misc/piesocket_event.dart';
import 'misc/piesocket_exception.dart';
import 'misc/piesocket_options.dart';
import 'pie_rtc.dart';

import 'package:flutter_webrtc/flutter_webrtc.dart' show MediaStream;

class PieSocket {
  String counter = "ok";

  late Map<String, Channel> rooms;
  late PieSocketOptions options;
  late Logger logger;

  /// The shared v4 socket every multiplexed `join()` rides — null under v3,
  /// or before the first v4 `join()` has opened it.
  Connection? connection;

  /// Set while the primary connection is resolving auth (fetching a JWT from
  /// authEndpoint) — a `join()` racing in during that window attaches once
  /// this resolves instead of trying to open a second primary. Resolves to
  /// the opened Connection, or null if opening the primary failed.
  Future<Connection?>? _multiplexOpening;

  PieSocket(PieSocketOptions pieSocketOptions) {
    rooms = HashMap();
    options = pieSocketOptions;
    logger = Logger(options.getEnableLogs());

    _validateOptions();
  }

  void _validateOptions() {
    if (options.getClusterId().isEmpty) {
      throw PieSocketException("Cluster ID is not provided");
    }

    if (options.getApiKey().isEmpty) {
      throw PieSocketException("API Key is not provided");
    }
  }

  /// Subscribe to a room. Always returns synchronously — under `version:
  /// "4"`, the first call opens a shared socket (this room becomes primary)
  /// and every later call rides it via a `system::subscribe` control frame
  /// sent in the background; listen for `system:connected` /
  /// `system::subscribe_error` / `system:error` on the returned [Channel] to
  /// know when it's actually live, the same way you'd listen for
  /// `system:connected` on v3. A guarded channel (`private-`/`forceAuth`)
  /// resolves its JWT from `authEndpoint` in the background the same way —
  /// `join()` never waits on that fetch.
  ///
  /// Pass [video], [audio], or [pieRTC] to mark this as a PieRTC (WebRTC)
  /// room — only meaningful under `version: "4"`; there is no v3 WebRTC
  /// support in this SDK. `channel.pieRTC` is attached once the room's
  /// underlying connection/subscribe resolves (which, like everything else
  /// in the multiplexed path, may be after `join()` already returned).
  Channel join(
    String roomId, {
    bool video = false,
    bool audio = false,
    bool pieRTC = false,
    bool shouldBroadcast = true,
    String cameraFacing = 'user',
    void Function(MediaStream stream, PieRTC pieRTC)? onLocalVideo,
    void Function(String uuid, MediaStream stream)? onParticipantJoined,
    void Function(String uuid)? onParticipantLeft,
    void Function(String uuid, String streamId)? onScreenSharingStopped,
  }) {
    if (rooms.containsKey(roomId)) {
      logger.debug("Returning existing room instance: $roomId");
      return rooms[roomId]!;
    }

    final isPieRTCRoom = video || audio || pieRTC;
    final rtcOptions = (isPieRTCRoom && options.getVersion() == "4")
        ? (PieRTCOptions(
            shouldBroadcast: shouldBroadcast,
            video: video,
            audio: audio,
            cameraFacing: cameraFacing,
            onLocalVideo: onLocalVideo,
            onParticipantJoined: onParticipantJoined,
            onParticipantLeft: onParticipantLeft,
            onScreenSharingStopped: onScreenSharingStopped,
          ))
        : null;

    Channel room = options.getVersion() == "4"
        ? _joinMultiplexed(roomId, rtcOptions)
        : Channel(roomId, options, logger);

    rooms[roomId] = room;

    return room;
  }

  Channel _joinMultiplexed(String roomId, PieRTCOptions? rtcOptions) {
    if (connection != null) {
      return _attachSecondary(roomId, connection!, rtcOptions);
    }

    if (_multiplexOpening != null) {
      // A primary is already resolving auth / connecting — attach once it's
      // ready instead of racing to open a second one.
      final channel = Channel.multiplexed(roomId, options, logger, null);
      _multiplexOpening!
          .then((_) => _attachOrRetry(roomId, channel, rtcOptions));
      return channel;
    }

    return _openPrimary(roomId, rtcOptions);
  }

  /// Re-evaluates where [roomId] (already returned to its caller as
  /// [channel]) should land once the primary open/attach it was waiting on
  /// has settled — re-checking `connection`/`_multiplexOpening` exactly like
  /// [_joinMultiplexed] does, rather than assuming a specific outcome. This
  /// keeps multiple joins queued behind the same failed primary from each
  /// independently retrying and racing each other: only whichever one runs
  /// first sets a new `_multiplexOpening`, and the rest queue behind it, same
  /// as any other join() would.
  void _attachOrRetry(
      String roomId, Channel channel, PieRTCOptions? rtcOptions) {
    if (connection != null) {
      _resolveAndAttach(roomId, channel, connection!, rtcOptions);
      return;
    }

    if (_multiplexOpening != null) {
      _multiplexOpening!
          .then((_) => _attachOrRetry(roomId, channel, rtcOptions));
      return;
    }

    // Nothing else came up in the meantime — this room still wants a
    // connection, so try opening the primary itself instead of leaving
    // `channel` permanently unattached.
    _openPrimary(roomId, rtcOptions, channel: channel);
  }

  Channel _openPrimary(String roomId, PieRTCOptions? rtcOptions,
      {Channel? channel}) {
    final resolvedChannel =
        channel ?? Channel.multiplexed(roomId, options, logger, null);
    final completer = Completer<Connection?>();
    _multiplexOpening = completer.future;

    AuthResolver.resolve(roomId, resolvedChannel.uuid, options, logger, (jwt) {
      final conn = Connection(
          roomId, options, logger, resolvedChannel.uuid, resolvedChannel,
          jwt: jwt);
      resolvedChannel.hub = conn;
      connection = conn;
      if (rtcOptions != null) {
        resolvedChannel.pieRTC = PieRTC(resolvedChannel, rtcOptions, logger);
      }
      _multiplexOpening = null;
      completer.complete(conn);
    }, (error) {
      logger.debug('PieSocket: auth resolution failed for "$roomId": $error');
      _fireErrorNextMicrotask(resolvedChannel, error);
      _multiplexOpening = null;
      completer.complete(null);
    });

    return resolvedChannel;
  }

  Channel _attachSecondary(
      String roomId, Connection conn, PieRTCOptions? rtcOptions) {
    final channel = Channel.multiplexed(roomId, options, logger, conn);
    _resolveAndAttach(roomId, channel, conn, rtcOptions);
    return channel;
  }

  void _resolveAndAttach(String roomId, Channel channel, Connection conn,
      PieRTCOptions? rtcOptions) {
    AuthResolver.resolve(roomId, channel.uuid, options, logger, (jwt) {
      final presence =
          options.getPresence() == 1 || roomId.startsWith('presence-');

      final Map<String, dynamic> params = {
        'channel': roomId,
        'presence': presence,
        'uuid': channel.uuid,
      };
      if (jwt != null) params['jwt'] = jwt;
      if (options.getUserId().isNotEmpty) params['user'] = options.getUserId();

      channel.subscribeParams = params;
      channel.hub = conn;
      conn.attachChannel(roomId, channel);
      if (rtcOptions != null) {
        channel.pieRTC = PieRTC(channel, rtcOptions, logger);
      }

      // Fire-and-forget: join() stays synchronous. A failure just logs — the
      // caller can listen for system::subscribe_error frames via '*' if they
      // need to react to it (the control frame itself never reaches this
      // channel's own listeners since Connection intercepts it beforehand).
      conn.subscribeChannel(roomId, params).catchError((e) {
        logger.debug('PieSocket: subscribe failed for "$roomId": $e');
      });
    }, (error) {
      logger.debug('PieSocket: auth resolution failed for "$roomId": $error');
      _fireErrorNextMicrotask(channel, error);
    });
  }

  /// Fires `system:error` on the next microtask rather than inline —
  /// AuthResolver's "no route to a token" case resolves synchronously
  /// (before join() even returns the channel to the caller), so firing
  /// immediately would mean no listener could ever be attached in time to
  /// observe it. Deferring one microtask means a caller doing
  /// `final ch = join(...); ch.listen('system:error', ...);` right after
  /// join() returns still catches it.
  void _fireErrorNextMicrotask(Channel channel, Object error) {
    scheduleMicrotask(() {
      channel
          .fireEvent(PieSocketEvent('system:error')..setData(error.toString()));
    });
  }

  void leave(String roomId) {
    if (!rooms.containsKey(roomId)) {
      logger.debug("DISCONNECT: Room does not exist: $roomId");
      return;
    }

    final channel = rooms[roomId]!;
    final conn = connection;

    // Stop any WebRTC media now, regardless of which teardown path runs below
    // (the primary-promotion branch doesn't call channel.disconnect()).
    final rtc = channel.pieRTC;
    if (rtc != null) {
      channel.pieRTC = null;
      rtc.dispose();
    }

    if (conn != null && channel.hub != null) {
      if (roomId == conn.primaryChannelId) {
        final others = conn.channels.keys.where((id) => id != roomId).toList();

        if (others.isEmpty) {
          conn.close();
          connection = null;
        } else {
          // Promote another subscription to primary and keep the rest.
          final newPrimaryId = others.first;
          final newPrimary = conn.channels[newPrimaryId]!;
          conn.detachChannel(roomId);

          AuthResolver.resolve(newPrimaryId, newPrimary.uuid, options, logger,
              (jwt) {
            final endpoint = Channel.buildUrl(
                newPrimaryId, options, newPrimary.uuid,
                jwt: jwt);
            conn.migratePrimary(newPrimaryId, endpoint,
                newUuid: newPrimary.uuid, newJwt: jwt);
          }, (error) {
            // Can't safely promote — primaryChannelId would keep pointing at
            // the room we just detached, leaving conn permanently unable to
            // route its "no system::channel tag" fallback. Tear the whole
            // shared connection down rather than leave it half-broken; every
            // remaining channel (including the one we tried to promote)
            // finds out via system:error and would need to join() again.
            logger.debug(
                'PieSocket: auth resolution failed while promoting "$newPrimaryId", closing shared connection: $error');
            final remainingIds = conn.channels.keys.toList();
            conn.close();
            connection = null;
            for (final id in remainingIds) {
              final ch = rooms.remove(id);
              if (ch != null) _fireErrorNextMicrotask(ch, error);
            }
          });
        }
      } else {
        channel.disconnect();
      }

      rooms.remove(roomId);
      return;
    }

    logger.debug("DISCONNECT: Closing room connection: $roomId");
    channel.disconnect();
    rooms.remove(roomId);
  }

  Map<String, Channel> getAllRooms() {
    return rooms;
  }
}
