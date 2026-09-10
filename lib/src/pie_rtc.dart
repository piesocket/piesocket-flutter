import 'channel.dart';
import 'misc/logger.dart';

import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Options for a [PieRTC] room, set via [PieSocket.join]'s named params.
class PieRTCOptions {
  bool shouldBroadcast;
  bool video;
  bool audio;

  /// Which camera to open for a [video] room: `'user'` (front — the default,
  /// what a 1:1 call wants) or `'environment'` (rear). Flip it at runtime with
  /// [PieRTC.switchCamera].
  String cameraFacing;

  void Function(MediaStream stream, PieRTC pieRTC)? onLocalVideo;
  void Function(String uuid, MediaStream stream)? onParticipantJoined;
  void Function(String uuid)? onParticipantLeft;
  void Function(String uuid, String streamId)? onScreenSharingStopped;

  PieRTCOptions({
    this.shouldBroadcast = true,
    this.video = false,
    this.audio = true,
    this.cameraFacing = 'user',
    this.onLocalVideo,
    this.onParticipantJoined,
    this.onParticipantLeft,
    this.onScreenSharingStopped,
  });
}

class _Participant {
  RTCPeerConnection? rtc;
  List<MediaStream>? streams;

  /// True when *this* client is the designated offerer for the peer — decided
  /// deterministically from the two uuids so exactly one side of every pair
  /// creates offers (no SDP glare in a 1:1 / mesh room).
  bool amOfferer = false;

  /// An offer we've sent and not yet had answered — suppresses a second offer
  /// while the first is in flight.
  bool makingOffer = false;

  /// True once a remote description is applied, so buffered ICE candidates can
  /// be flushed (flutter_webrtc rejects `addCandidate` before that).
  bool remoteDescriptionSet = false;
  final List<RTCIceCandidate> pendingCandidates = [];

  /// stream ids already surfaced through [PieRTCOptions.onParticipantJoined],
  /// so a multi-track stream (audio + video) fires the callback only once.
  final Set<String> announcedStreams = {};
}

/// PieRTC — programmable WebRTC video/audio rooms over a v4 [Channel].
///
/// Mirrors piesocket-js's `PieRTC.js`, adapted to `flutter_webrtc`'s API where
/// it differs from the browser-native one it wraps: `addCandidate` instead of
/// `addIceCandidate` and `onTrack`/`RTCTrackEvent` instead of `ontrack`'s raw
/// event. `navigator.mediaDevices.getUserMedia`/`getDisplayMedia` are the same
/// names as the browser API.
///
/// Signalling rides the channel via `publishEvent` on the same `rtc::`
/// namespace the JS SDK uses — a plain PieSocket relay, no server-side
/// special-casing, so this and the JS client can be mixed in the same room.
///
/// **Handshake (collision-free, and not dependent on the native
/// `onnegotiationneeded` event, which is unreliable on mobile):**
///  * Each client announces with `rtc::broadcaster` (or `rtc::watcher`), and
///    re-announces whenever a member joins — so a peer that was already in the
///    room hears a late joiner.
///  * For every peer pair, the client with the larger uuid is the **sole
///    offerer**. On hearing a peer it creates the connection and sends an
///    offer outright; the other side only ever answers. It nudges the offerer
///    with `rtc::request` (and, post-connection, `rtc::renegotiate`).
class PieRTC {
  final Channel channel;
  final PieRTCOptions identity;
  final Logger _logger;

  MediaStream? localStream;
  MediaStream? displayStream;

  /// Current camera, kept in sync by [switchCamera]. Starts at
  /// [PieRTCOptions.cameraFacing].
  bool get isFrontCamera => _frontCamera;
  bool _frontCamera = true;

  final Map<String, dynamic> peerConnectionConfig = {
    'iceServers': [
      {'urls': 'stun:stun.stunprotocol.org:3478'},
      {'urls': 'stun:stun.l.google.com:19302'},
    ],
  };

  final Map<String, _Participant> participants = {};

  /// In-flight `createPeerConnection` calls, so two concurrent signals for the
  /// same peer share one connection instead of racing to build two.
  final Map<String, Future<_Participant?>> _peerSetup = {};

  PieRTC(this.channel, this.identity, this._logger) {
    _logger.debug('Initializing video room');
    _frontCamera = identity.cameraFacing != 'environment';
    _init();
  }

  Future<void> _init() async {
    if (!identity.video && !identity.audio) {
      requestPeerVideo();
      return;
    }

    try {
      final stream = await navigator.mediaDevices.getUserMedia({
        'audio': identity.audio,
        'video': identity.video
            ? {'facingMode': identity.cameraFacing, 'optional': const []}
            : false,
      });
      _getUserMediaSuccess(stream);
    } catch (e) {
      _logger.debug('PieRTC: getUserMedia failed: $e');
    }
  }

  void _getUserMediaSuccess(MediaStream stream) {
    localStream = stream;
    _logger.debug('PieRTC: local stream ready (${channel.uuid})');
    identity.onLocalVideo?.call(stream, this);
    requestPeerVideo();
  }

  /// Flip between the front and rear camera on the live call. Safe to call any
  /// time after [PieRTCOptions.onLocalVideo] has fired; no renegotiation
  /// needed — the same track keeps streaming from the other lens. Returns the
  /// new [isFrontCamera] value (or the unchanged one if there's no camera).
  Future<bool> switchCamera() async {
    final tracks = localStream?.getVideoTracks() ?? const [];
    if (tracks.isEmpty) return _frontCamera;
    try {
      final front = await Helper.switchCamera(tracks.first);
      _frontCamera = front;
    } catch (e) {
      _logger.debug('PieRTC: switchCamera failed: $e');
    }
    return _frontCamera;
  }

  /// Set once this client has media (or is a no-media room) and has made its
  /// first announcement — gates [onMemberJoined] so we don't announce before
  /// we can actually carry the call.
  bool _announced = false;

  void requestPeerVideo() {
    _announced = true;
    final eventName =
        identity.shouldBroadcast ? 'rtc::broadcaster' : 'rtc::watcher';
    channel.publishEvent(eventName, data: {
      'from': channel.uuid,
      'isBroadcasting': identity.shouldBroadcast,
    });
  }

  void requestOfferFromPeer() {
    channel.publishEvent('rtc::request', data: {
      'from': channel.uuid,
      'isBroadcasting': identity.shouldBroadcast,
    });
  }

  /// A member joined the room — re-announce so a peer already here learns about
  /// this client (and vice versa), and so a late joiner triggers a fresh offer.
  void onMemberJoined() {
    if (_announced) requestPeerVideo();
  }

  /// True when this client should be the one to create offers toward [peer].
  /// Deterministic and symmetric: both sides compute the same answer.
  bool _amOffererFor(String peer) => channel.uuid.compareTo(peer) > 0;

  /// A peer announced itself (`rtc::broadcaster`/`rtc::watcher`) or asked us
  /// for an offer (`rtc::request`). This is the whole handshake trigger.
  void onPeerSignal(Map signal) {
    final from = signal['from'] as String?;
    if (from == null || from == channel.uuid) return;
    _logger.debug('PieRTC: peer signal from $from');

    if (_amOffererFor(from)) {
      _sendOffer(from);
    } else {
      // The peer is the offerer — make sure it knows we're here and waiting.
      requestOfferFromPeer();
    }
  }

  /// Backwards-compatible alias — older callers (and the JS-mirrored dispatch)
  /// used `shareVideo` for the broadcaster/watcher/request path.
  Future<void> shareVideo(Map signal, [bool isCaller = true]) async {
    onPeerSignal(signal);
  }

  Future<_Participant?> _ensurePeer(String from) {
    final existing = participants[from];
    if (existing?.rtc != null) return Future.value(existing);
    return _peerSetup.putIfAbsent(from, () => _createPeer(from));
  }

  Future<_Participant?> _createPeer(String from) async {
    _logger.debug('PieRTC: creating peer connection for $from');
    final participant = _Participant()..amOfferer = _amOffererFor(from);
    participants[from] = participant;

    try {
      final pc = await createPeerConnection(peerConnectionConfig, {});
      participant.rtc = pc;

      pc.onIceCandidate = (candidate) {
        channel.publishEvent('rtc::candidate', data: {
          'from': channel.uuid,
          'to': from,
          'ice': candidate.toMap(),
        });
      };

      pc.onConnectionState = (state) {
        _logger.debug('PieRTC: connection[$from] = $state');
      };

      pc.onTrack = (event) {
        if (event.streams.isEmpty) return;
        final stream = event.streams.first;
        participant.streams = event.streams;
        if (participant.announcedStreams.add(stream.id)) {
          identity.onParticipantJoined?.call(from, stream);
        }
      };

      pc.onRenegotiationNeeded = () async {
        // Only relevant after the first connection (track added/removed later).
        if (!participant.remoteDescriptionSet) return;
        if (participant.amOfferer) {
          await _sendOffer(from);
        } else {
          channel.publishEvent('rtc::renegotiate',
              data: {'from': channel.uuid, 'to': from});
        }
      };

      for (final track in localStream?.getTracks() ?? const []) {
        await pc.addTrack(track, localStream!);
      }
      for (final track in displayStream?.getTracks() ?? const []) {
        await pc.addTrack(track, displayStream!);
      }

      return participant;
    } catch (e) {
      participants.remove(from);
      _logger.debug('PieRTC: createPeerConnection failed: $e');
      return null;
    } finally {
      _peerSetup.remove(from);
    }
  }

  Future<void> _sendOffer(String from) async {
    final participant = await _ensurePeer(from);
    final pc = participant?.rtc;
    if (participant == null || pc == null || participant.makingOffer) return;

    final state = pc.signalingState;
    if (state != null && state != RTCSignalingState.RTCSignalingStateStable) {
      return;
    }

    participant.makingOffer = true;
    try {
      final description = await pc.createOffer();
      await pc.setLocalDescription(description);
      _logger.debug('PieRTC: sending offer to $from');
      channel.publishEvent('rtc::offer', data: {
        'from': channel.uuid,
        'to': from,
        'sdp': {'sdp': description.sdp, 'type': description.type},
      });
    } catch (e) {
      participant.makingOffer = false;
      _logger.debug('PieRTC: sending offer failed: $e');
    }
  }

  /// The peer poked us (its designated offerer) for a fresh offer.
  Future<void> renegotiate(String from) async {
    if (!_amOffererFor(from)) return;
    await _sendOffer(from);
  }

  Future<void> createAnswer(Map signal) async {
    final from = signal['from'] as String;
    final sdpMap = signal['sdp'] as Map;
    final type = sdpMap['type'] as String?;

    if (type != 'offer') return;

    if (_amOffererFor(from)) {
      // We're the offerer for this peer — a crossing offer is spurious.
      _logger.debug('Ignoring offer from $from — we are the offerer');
      return;
    }

    final participant = await _ensurePeer(from);
    final pc = participant?.rtc;
    if (participant == null || pc == null) return;

    try {
      await pc.setRemoteDescription(
          RTCSessionDescription(sdpMap['sdp'] as String?, type));
      await _flushCandidates(participant);
      final description = await pc.createAnswer();
      await pc.setLocalDescription(description);
      _logger.debug('PieRTC: sending answer to $from');
      channel.publishEvent('rtc::answer', data: {
        'from': channel.uuid,
        'to': from,
        'sdp': {'sdp': description.sdp, 'type': description.type},
      });
    } catch (e) {
      _logger.debug('PieRTC: answering failed: $e');
    }
  }

  Future<void> handleAnswer(Map signal) async {
    final participant = participants[signal['from']];
    final pc = participant?.rtc;
    if (participant == null || pc == null) return;

    if (pc.signalingState !=
        RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
      _logger.debug('Ignoring answer from ${signal['from']} — not expecting one');
      return;
    }

    final sdpMap = signal['sdp'] as Map;
    try {
      await pc.setRemoteDescription(RTCSessionDescription(
          sdpMap['sdp'] as String?, sdpMap['type'] as String?));
      participant.makingOffer = false;
      await _flushCandidates(participant);
    } catch (e) {
      participant.makingOffer = false;
      _logger.debug('PieRTC: setRemoteDescription (answer) failed: $e');
    }
  }

  Future<void> addIceCandidate(Map signal) async {
    final participant = participants[signal['from']];
    if (participant == null) return;

    final ice = signal['ice'] as Map;
    final candidate = RTCIceCandidate(
      ice['candidate'] as String?,
      ice['sdpMid'] as String?,
      ice['sdpMLineIndex'] as int?,
    );

    if (participant.rtc == null || !participant.remoteDescriptionSet) {
      participant.pendingCandidates.add(candidate);
      return;
    }
    try {
      await participant.rtc!.addCandidate(candidate);
    } catch (e) {
      _logger.debug('PieRTC: addCandidate failed: $e');
    }
  }

  Future<void> _flushCandidates(_Participant participant) async {
    participant.remoteDescriptionSet = true;
    if (participant.pendingCandidates.isEmpty) return;
    final pending = List<RTCIceCandidate>.from(participant.pendingCandidates);
    participant.pendingCandidates.clear();
    for (final candidate in pending) {
      try {
        await participant.rtc!.addCandidate(candidate);
      } catch (e) {
        _logger.debug('PieRTC: buffered addCandidate failed: $e');
      }
    }
  }

  void removeParticipant(String uuid) {
    final participant = participants.remove(uuid);
    participant?.rtc?.close();
    identity.onParticipantLeft?.call(uuid);
  }

  /// Tear the room down: close every peer connection and stop the local
  /// camera/mic (and any screen share) so nothing keeps capturing or
  /// streaming after the call ends. Called automatically when the channel is
  /// left; safe to call more than once.
  bool _disposed = false;
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _logger.debug('PieRTC: disposing room');

    _peerSetup.clear();
    for (final participant in participants.values) {
      try {
        await participant.rtc?.close();
      } catch (_) {}
      participant.pendingCandidates.clear();
    }
    participants.clear();

    await _stopStream(localStream);
    localStream = null;
    await _stopStream(displayStream);
    displayStream = null;
  }

  Future<void> _stopStream(MediaStream? stream) async {
    if (stream == null) return;
    for (final track in stream.getTracks()) {
      try {
        await track.stop();
      } catch (_) {}
    }
    try {
      await stream.dispose();
    } catch (_) {}
  }

  Future<void> onRemoteScreenStopped(String uuid, String streamId) async {
    identity.onScreenSharingStopped?.call(uuid, streamId);
  }

  Future<void> onLocalScreen(MediaStream screenStream) async {
    final videoTracks = screenStream.getVideoTracks();
    if (videoTracks.isNotEmpty) {
      videoTracks.first.onEnded = () {
        stopScreenShare();
      };
    }

    // Send it to every peer (in addition to the camera).
    displayStream = screenStream;
    for (final participant in participants.values) {
      final pc = participant.rtc;
      if (pc == null) continue;
      for (final track in screenStream.getTracks()) {
        await pc.addTrack(track, screenStream); // -> onRenegotiationNeeded
      }
    }
  }

  /// Start sharing this device's screen with everyone in the room. One call —
  /// the SDK requests the capture and renegotiates the screen track onto every
  /// peer connection, alongside the camera.
  ///
  /// Zero-config on web, desktop, macOS and iOS (iOS uses in-app ReplayKit
  /// capture). **Android** additionally needs the app to run a foreground
  /// service of type `mediaProjection` while sharing — see the README.
  Future<void> shareScreen() async {
    if (displayStream != null) {
      _logger.debug('PieRTC: screen share already active');
      return;
    }
    try {
      final stream =
          await navigator.mediaDevices.getDisplayMedia({'video': true});
      await onLocalScreen(stream);
    } catch (e) {
      _logger.debug('PieRTC: getDisplayMedia failed: $e');
    }
  }

  /// Stop screen sharing started by [shareScreen].
  Future<void> stopScreenShare() async {
    final stream = displayStream;
    if (stream == null) return;
    final streamId = stream.id;
    displayStream = null;

    final screenTrackIds = stream.getTracks().map((t) => t.id).toSet();
    for (final participant in participants.values) {
      final pc = participant.rtc;
      if (pc == null) continue;
      final senders = await pc.getSenders();
      for (final sender in senders) {
        if (screenTrackIds.contains(sender.track?.id)) {
          await pc.removeTrack(sender); // -> onRenegotiationNeeded
        }
      }
    }

    for (final track in stream.getTracks()) {
      await track.stop();
    }
    await stream.dispose();

    channel.publishEvent('rtc::stopped_screen',
        data: {'from': channel.uuid, 'streamId': streamId});
    identity.onScreenSharingStopped?.call(channel.uuid, streamId);
  }
}
