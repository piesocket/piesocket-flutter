import 'dart:async';

import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'channel.dart';
import 'misc/logger.dart';
import 'pie_call_push.dart';
import 'pie_call_types.dart';
import 'piesocket.dart';

/// One-line-integration 1:1 calling on top of PieSocket.
///
/// Wires three things together so the app doesn't have to:
///  * **Signalling** — you forward the `call_invite` / `call_accept` /
///    `call_end` (and optional `call_cancel`) events you already receive on
///    `private-user-<id>` via [handleSignal].
///  * **Native call UI** — CallKit (iOS) / full-screen incoming-call
///    notification (Android) via `flutter_callkit_incoming`, including ring,
///    screen-wake and lock-screen answer. Push wake-up is handled by
///    [PieCallPush] in your FCM background handler + (iOS) the PushKit hooks in
///    your AppDelegate.
///  * **Media** — the glare-free [PieRTC] already in this package.
///
/// The app stays authoritative over its own call records: [PieCall] calls back
/// through [onAccept] / [onDecline] / [onHangUp] so you can hit your REST API,
/// and [onEnsureConnected] so you can bring the socket back up after a cold
/// start before answering.
class PieCall {
  PieCall({
    required PieSocket? Function() socket,
    required int Function() selfUserId,
    this.config = const PieCallConfig(),
    Logger? logger,
  })  : _socket = socket,
        _selfUserId = selfUserId,
        _logger = logger ?? Logger(false) {
    _eventSub = FlutterCallkitIncoming.onEvent.listen(
      _onCallKitEvent,
      onError: (Object e) => _logger.debug('PieCall: callkit event error: $e'),
    );
    _requestPermissions();
  }

  final PieSocket? Function() _socket;
  final int Function() _selfUserId;
  final PieCallConfig config;
  final Logger _logger;

  /// This device's user id, as your app knows it.
  int get selfUserId => _selfUserId();

  // ── Callbacks the host app wires up ───────────────────────────────────────

  /// Accept the incoming call server-side (e.g. `POST /calls/{id}/accept`).
  /// Return `false` to abort — e.g. the server says another of the user's
  /// devices already answered. Anything else (incl. a thrown error) proceeds.
  Future<bool> Function(int callId)? onAccept;

  /// Decline server-side (e.g. `POST /calls/{id}/decline`).
  Future<void> Function(int callId)? onDecline;

  /// End server-side. `reason` is one of `completed` / `cancelled` / `missed`.
  Future<void> Function(int callId, String reason)? onHangUp;

  /// Bring the realtime socket back up (after a push cold-start) before we try
  /// to join the media room. Awaited before answering.
  Future<void> Function()? onEnsureConnected;

  // ── State ────────────────────────────────────────────────────────────────

  final _updates = StreamController<PieCallSnapshot>.broadcast();
  final _voipTokenChanges = StreamController<String>.broadcast();

  PieCallSnapshot _snap = const PieCallSnapshot();
  PieCallSnapshot get snapshot => _snap;
  Stream<PieCallSnapshot> get updates => _updates.stream;

  MediaStream? _localStream;
  MediaStream? _remoteStream;
  MediaStream? get localStream => _localStream;
  MediaStream? get remoteStream => _remoteStream;

  Stream<String> get voipTokenChanges => _voipTokenChanges.stream;

  StreamSubscription? _eventSub;
  Channel? _callChannel;
  Timer? _ringTimeout;
  bool _joining = false;
  bool _accepting = false;
  bool _everActive = false;

  /// True from the first teardown step until the call returns to idle — so the
  /// `actionCallEnded` our own `endCall()` triggers (and a duplicate `call_end`)
  /// don't re-enter teardown and clobber the end reason.
  bool _ending = false;

  /// Call ids already finished — guards against a late invite (the VoIP push
  /// racing the socket) re-ringing a call that's already over.
  final _recentlyEnded = <int>{};

  PieCallInvite? get _invite => _snap.invite;

  // ── Public API ───────────────────────────────────────────────────────────

  /// The iOS PushKit VoIP token to register with your backend. `null` on
  /// Android / simulator.
  static Future<String?> voipToken() async {
    try {
      return await FlutterCallkitIncoming.getDevicePushTokenVoIP();
    } catch (_) {
      return null;
    }
  }

  /// Feed a `call_*` signalling event through. `event` is the PieSocket event
  /// name; `data` its payload.
  void handleSignal(String event, Map data) {
    _logger.debug('PieCall: signal $event call_id=${data['call_id']}');
    switch (event) {
      case 'call_invite':
        _onInvite(PieCallInvite.fromMap(data));
        break;
      case 'call_accept':
        final id = _asInt(data['call_id']);
        if (_invite?.callId == id && _snap.outgoing) {
          _clearRingTimeout();
          _emit(phase: PieCallPhase.connecting);
          _joinRtc();
        }
        break;
      case 'call_end':
        final id = _asInt(data['call_id']);
        if (_invite?.callId == id) {
          _teardown((data['status'] ?? 'ended').toString());
        }
        break;
      case 'call_cancel':
        // A "stop ringing" fanned out to every device. Honour it only while
        // this device is still *ringing* — one that's answering or in the call
        // ignores its own cancel.
        final uuid = '${data['call_uuid'] ?? data['id'] ?? ''}';
        final mine = _invite != null &&
            (_invite!.uuid == uuid ||
                _invite!.callId == _asInt(data['call_id']));
        final ringing = _snap.phase == PieCallPhase.ringing && !_accepting;
        if (mine && ringing) {
          _teardown('cancelled');
        }
        break;
    }
  }

  /// Place an outgoing call. The app has already created the call server-side
  /// (`POST /calls`) and passes the returned id/uuid/room here.
  ///
  /// Outgoing calls do **not** register with CallKit — the app shows its own
  /// "calling…" UI. CallKit is only for *incoming* calls (waking a dead app).
  Future<void> startOutgoing({required PieCallInvite invite}) async {
    _logger.debug('PieCall: startOutgoing call=${invite.callId}');
    if (_snap.phase != PieCallPhase.idle) return;
    _snap = PieCallSnapshot(
      phase: PieCallPhase.dialing,
      invite: invite,
      outgoing: true,
      speakerOn: invite.video,
    );
    _emit();
    _armRingTimeout();
  }

  /// Answer the current incoming call.
  Future<void> accept() async {
    final inv = _invite;
    if (inv == null || _snap.outgoing || _accepting || _ending) return;
    if (_snap.phase == PieCallPhase.connecting ||
        _snap.phase == PieCallPhase.active) {
      return;
    }
    _accepting = true;
    _clearRingTimeout();
    _emit(phase: PieCallPhase.connecting);
    bool proceed = true;
    try {
      await onEnsureConnected?.call();
      proceed = (await onAccept?.call(inv.callId)) ?? true;
    } catch (e) {
      _logger.debug('PieCall: onAccept failed: $e');
    }
    _accepting = false;
    if (!proceed) {
      // Another of the user's devices grabbed the call.
      _teardown('answered_elsewhere');
      return;
    }
    await _joinRtc();
  }

  /// Reject the current incoming call.
  Future<void> decline() async {
    final inv = _invite;
    if (inv == null || _ending) return;
    try {
      await onDecline?.call(inv.callId);
    } catch (_) {}
    _teardown('declined');
  }

  /// Hang up (or cancel a call that's still ringing).
  Future<void> hangUp() async {
    final inv = _invite;
    if (inv == null || _ending) return;
    final reason = _everActive ? 'completed' : 'cancelled';
    try {
      await onHangUp?.call(inv.callId, reason);
    } catch (_) {}
    _teardown(reason);
  }

  // ── Media controls ───────────────────────────────────────────────────────

  Future<void> toggleMute() async {
    final muted = !_snap.muted;
    for (final t in _localStream?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = !muted;
    }
    _emit(muted: muted);
  }

  Future<void> toggleCamera() async {
    final on = !_snap.cameraOn;
    for (final t in _localStream?.getVideoTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = on;
    }
    _emit(cameraOn: on);
  }

  Future<void> switchCamera() async {
    final front = await _callChannel?.pieRTC?.switchCamera() ?? _snap.frontCamera;
    _emit(frontCamera: front);
  }

  Future<void> setSpeaker(bool on) async {
    try {
      await Helper.setSpeakerphoneOn(on);
    } catch (_) {}
    _emit(speakerOn: on);
  }

  // ── CallKit events ───────────────────────────────────────────────────────

  Future<void> _onCallKitEvent(CallEvent? event) async {
    switch (event) {
      case CallEventActionCallIncoming(:final callKitParams):
        // Shown by a push while we were dead — rebuild the invite from `extra`.
        if (_invite == null) {
          final extra = callKitParams.extra ?? const <String, dynamic>{};
          if (PieCallPush.isCallPush(extra) || extra['call_id'] != null) {
            _onInvite(PieCallInvite.fromMap({
              ...extra,
              'call_uuid': extra['call_uuid'] ?? callKitParams.id,
            }));
          }
        }
        break;
      case CallEventActionCallAccept():
        await accept();
        break;
      case CallEventActionCallDecline():
        await decline();
        break;
      case CallEventActionCallEnded():
        await hangUp();
        break;
      case CallEventActionCallTimeout():
        await _onTimeout();
        break;
      case CallEventActionCallToggleMute(:final isMuted):
        for (final t in _localStream?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
          t.enabled = !isMuted;
        }
        _emit(muted: isMuted);
        break;
      case CallEventActionCallToggleHold(:final isOnHold):
        // iOS parked our call (e.g. a phone call came in). Pause the media.
        for (final t in _localStream?.getTracks() ?? const <MediaStreamTrack>[]) {
          t.enabled = !isOnHold;
        }
        break;
      case CallEventActionDidUpdateDevicePushTokenVoip():
        final t = await voipToken();
        if (t != null && t.isNotEmpty) _voipTokenChanges.add(t);
        break;
      default:
        break;
    }
  }

  // ── Internals ────────────────────────────────────────────────────────────

  void _onInvite(PieCallInvite invite) {
    if (_recentlyEnded.contains(invite.callId)) return; // late push for a done call
    if (_invite != null && _invite!.callId != invite.callId) {
      // Busy — auto-decline the newcomer.
      onDecline?.call(invite.callId);
      return;
    }
    if (_invite?.callId == invite.callId) return; // already ringing (push + socket)
    _snap = PieCallSnapshot(phase: PieCallPhase.ringing, invite: invite);
    _emit();
    // CallKit may already be up (push path); showing again is a no-op for the
    // same uuid.
    FlutterCallkitIncoming.showCallkitIncoming(
      PieCallPush.params(_inviteToMap(invite), config.appName),
    );
    _armRingTimeout();
  }

  Future<void> _joinRtc() async {
    final inv = _invite;
    final pie = _socket();
    if (inv == null || pie == null || _joining || _ending) {
      if (pie == null) _teardown('failed');
      return;
    }
    _joining = true;
    try {
      _callChannel = pie.join(
        inv.room,
        audio: true,
        video: inv.video,
        pieRTC: true,
        cameraFacing: 'user',
        onLocalVideo: (stream, _) {
          _localStream = stream;
          for (final t in stream.getAudioTracks()) {
            t.enabled = !_snap.muted;
          }
          _emit();
        },
        onParticipantJoined: (_, stream) {
          _remoteStream = stream;
          _markActive();
        },
        onParticipantLeft: (_) {
          // A member_left before media ever flowed is almost always presence
          // noise from our own (re)connect, not the peer hanging up. Only tear
          // down once the call has actually been active.
          if (_everActive) hangUp();
        },
      );
      if (inv.video && !_snap.speakerOn) {
        await setSpeaker(true);
      }
    } catch (e) {
      _logger.debug('PieCall: joinRtc failed: $e');
      _teardown('failed');
    } finally {
      _joining = false;
    }
  }

  void _markActive() {
    if (_snap.phase == PieCallPhase.active || _ending) return;
    _everActive = true;
    final inv = _invite;
    _emit(phase: PieCallPhase.active, connectedAt: DateTime.now());
    if (inv != null) {
      FlutterCallkitIncoming.setCallConnected(inv.uuid);
    }
  }

  Future<void> _onTimeout() async {
    if (_snap.phase != PieCallPhase.ringing &&
        _snap.phase != PieCallPhase.dialing) {
      return;
    }
    final inv = _invite;
    if (inv != null) {
      try {
        await onHangUp?.call(inv.callId, 'missed');
      } catch (_) {}
    }
    _teardown('missed');
  }

  void _armRingTimeout() {
    _clearRingTimeout();
    _ringTimeout = Timer(config.ringDuration, _onTimeout);
  }

  void _clearRingTimeout() {
    _ringTimeout?.cancel();
    _ringTimeout = null;
  }

  Future<void> _dismissCallKit() async {
    final inv = _invite;
    try {
      if (inv != null) {
        await FlutterCallkitIncoming.endCall(inv.uuid);
      } else {
        await FlutterCallkitIncoming.endAllCalls();
      }
    } catch (_) {}
  }

  void _teardown(String reason) {
    if (_ending) return;
    _ending = true;
    _logger.debug('PieCall: teardown ($reason)');
    _clearRingTimeout();
    _dismissCallKit(); // always end the native call, or it lingers (hold/swap)
    final inv = _invite;
    if (inv != null) {
      _recentlyEnded.add(inv.callId);
      if (_recentlyEnded.length > 20) {
        _recentlyEnded.remove(_recentlyEnded.first);
      }
      _socket()?.leave(inv.room); // disposes PieRTC -> stops camera/mic
    }
    _callChannel = null;
    _localStream = null;
    _remoteStream = null;
    _everActive = false;
    _joining = false;
    _emit(phase: PieCallPhase.ended, endReason: reason);
    Future.delayed(const Duration(milliseconds: 800), () {
      _snap = const PieCallSnapshot();
      _ending = false;
      _emit();
    });
  }

  Future<void> _requestPermissions() async {
    try {
      await FlutterCallkitIncoming.requestNotificationPermission({
        'title': 'Notifications',
        'rationaleMessagePermission':
            'Allow notifications so you can see incoming calls.',
        'postNotificationMessageRequired':
            'Turn on notifications in Settings to receive calls.',
      });
      if (await FlutterCallkitIncoming.canUseFullScreenIntent() == false) {
        await FlutterCallkitIncoming.requestFullIntentPermission();
      }
    } catch (_) {}
  }

  void _emit({
    PieCallPhase? phase,
    DateTime? connectedAt,
    String? endReason,
    bool? muted,
    bool? cameraOn,
    bool? speakerOn,
    bool? frontCamera,
  }) {
    _snap = _snap.copyWith(
      phase: phase,
      connectedAt: connectedAt,
      endReason: endReason,
      muted: muted,
      cameraOn: cameraOn,
      speakerOn: speakerOn,
      frontCamera: frontCamera,
    );
    if (!_updates.isClosed) _updates.add(_snap);
  }

  Map<String, dynamic> _inviteToMap(PieCallInvite i) => {
        'call_id': i.callId,
        'call_uuid': i.uuid,
        'room': i.room,
        'media': i.video ? 'video' : 'audio',
        'is_video': i.video ? 'true' : 'false',
        'from_id': i.peerId,
        'from_name': i.peerName,
        if (i.peerAvatar != null) 'from_avatar': i.peerAvatar,
      };

  static int _asInt(Object? v) => v is int ? v : int.tryParse('$v') ?? 0;

  void dispose() {
    _clearRingTimeout();
    _eventSub?.cancel();
    _updates.close();
    _voipTokenChanges.close();
  }
}
