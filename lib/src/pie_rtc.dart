import 'channel.dart';
import 'misc/logger.dart';

import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Options for a [PieRTC] room, set via [PieSocket.join]'s named params.
class PieRTCOptions {
  bool shouldBroadcast;
  bool video;
  bool audio;
  void Function(MediaStream stream, PieRTC pieRTC)? onLocalVideo;
  void Function(String uuid, MediaStream stream)? onParticipantJoined;
  void Function(String uuid)? onParticipantLeft;
  void Function(String uuid, String streamId)? onScreenSharingStopped;

  PieRTCOptions({
    this.shouldBroadcast = true,
    this.video = false,
    this.audio = true,
    this.onLocalVideo,
    this.onParticipantJoined,
    this.onParticipantLeft,
    this.onScreenSharingStopped,
  });
}

class _Participant {
  RTCPeerConnection? rtc;
  List<MediaStream>? streams;
}

/// PieRTC — programmable WebRTC video/audio rooms over a v4 [Channel].
///
/// Mirrors piesocket-js's `PieRTC.js` method-for-method (itself the v4
/// counterpart of the older v3 `Portal.js`), adapted to `flutter_webrtc`'s
/// API where it differs from the browser-native one it wraps: `addCandidate`
/// instead of `addIceCandidate`, `onRenegotiationNeeded` (no event arg)
/// instead of `onnegotiationneeded`, and `onTrack`/`RTCTrackEvent` instead of
/// `ontrack`'s raw event. `navigator.mediaDevices.getUserMedia`/
/// `getDisplayMedia` are the same names as the browser API.
///
/// Signalling rides the channel via `publishEvent` on the same `rtc::`
/// namespace the JS SDK uses — a plain PieSocket relay, no server-side
/// special-casing, so this and the JS client can be mixed in the same room.
class PieRTC {
  final Channel channel;
  final PieRTCOptions identity;
  final Logger _logger;

  MediaStream? localStream;
  MediaStream? displayStream;

  final Map<String, dynamic> peerConnectionConfig = {
    'iceServers': [
      {'urls': 'stun:stun.stunprotocol.org:3478'},
      {'urls': 'stun:stun.l.google.com:19302'},
    ],
  };

  final Map<String, _Participant> participants = {};
  final Map<String, bool> _isNegotiating = {};

  PieRTC(this.channel, this.identity, this._logger) {
    _logger.debug('Initializing video room');
    _init();
  }

  Future<void> _init() async {
    if (!identity.video && !identity.audio) {
      requestPeerVideo();
      return;
    }

    try {
      final stream = await navigator.mediaDevices.getUserMedia({
        'video': identity.video,
        'audio': identity.audio,
      });
      _getUserMediaSuccess(stream);
    } catch (e) {
      _logger.debug('PieRTC: getUserMedia failed: $e');
    }
  }

  void _getUserMediaSuccess(MediaStream stream) {
    localStream = stream;
    identity.onLocalVideo?.call(stream, this);
    requestPeerVideo();
  }

  void requestPeerVideo() {
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

  Future<void> shareVideo(Map signal, [bool isCaller = true]) async {
    final from = signal['from'] as String;

    if (!identity.shouldBroadcast &&
        isCaller &&
        signal['isBroadcasting'] != true) {
      _logger.debug('Refusing to call, denied broadcast request');
      return;
    }

    final pc = await createPeerConnection(peerConnectionConfig, {});

    pc.onIceCandidate = (candidate) {
      channel.publishEvent('rtc::candidate', data: {
        'from': channel.uuid,
        'to': from,
        'ice': candidate.toMap(),
      });
    };

    pc.onTrack = (event) {
      if (event.track.kind != 'video') return;

      participants[from]?.streams = event.streams;
      if (event.streams.isNotEmpty) {
        identity.onParticipantJoined?.call(from, event.streams.first);
      }
    };

    pc.onSignalingState = (state) {
      // Workaround for Chrome: skip nested negotiations.
      _isNegotiating[from] = state != RTCSignalingState.RTCSignalingStateStable;
    };

    if (localStream != null) {
      for (final track in localStream!.getTracks()) {
        await pc.addTrack(track, localStream!);
      }
    }

    if (displayStream != null) {
      for (final track in displayStream!.getTracks()) {
        await pc.addTrack(track, displayStream!);
      }
    }

    _isNegotiating[from] = false;

    pc.onRenegotiationNeeded = () async {
      await _sendVideoOffer(from, pc);
    };

    participants[from] = _Participant()..rtc = pc;
  }

  Future<void> onRemoteScreenStopped(String uuid, String streamId) async {
    identity.onScreenSharingStopped?.call(uuid, streamId);
  }

  Future<void> onLocalScreen(MediaStream screenStream) async {
    // The user stopped the share from the OS UI — tear everything down.
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
  ///
  /// Call [stopScreenShare] to stop; the SDK also stops if the user ends the
  /// share from the OS UI. Either way it fires
  /// [PieRTCOptions.onScreenSharingStopped] with this client's own uuid and
  /// publishes `rtc::stopped_screen` to the room.
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

  Future<void> _sendVideoOffer(String from, RTCPeerConnection pc) async {
    if (_isNegotiating[from] == true) {
      _logger.debug('SKIP nested negotiations');
      return;
    }

    _isNegotiating[from] = true;

    final description = await pc.createOffer();
    await pc.setLocalDescription(description);

    channel.publishEvent('rtc::offer', data: {
      'from': channel.uuid,
      'to': from,
      'sdp': {'sdp': description.sdp, 'type': description.type},
    });
  }

  void removeParticipant(String uuid) {
    participants.remove(uuid);
    identity.onParticipantLeft?.call(uuid);
  }

  Future<void> addIceCandidate(Map signal) async {
    final pc = participants[signal['from']]?.rtc;
    if (pc == null) return;

    final ice = signal['ice'] as Map;
    await pc.addCandidate(RTCIceCandidate(
      ice['candidate'] as String?,
      ice['sdpMid'] as String?,
      ice['sdpMLineIndex'] as int?,
    ));
  }

  Future<void> createAnswer(Map signal) async {
    final from = signal['from'] as String;

    if (participants[from]?.rtc == null) {
      _logger.debug('Starting call in createAnswer');
      await shareVideo(signal, false);
    }

    final pc = participants[from]!.rtc!;
    final sdpMap = signal['sdp'] as Map;
    await pc.setRemoteDescription(RTCSessionDescription(
        sdpMap['sdp'] as String?, sdpMap['type'] as String?));

    // Only create answers in response to offers.
    if (sdpMap['type'] == 'offer') {
      _logger.debug('Got an offer from $from');
      final description = await pc.createAnswer();
      await pc.setLocalDescription(description);

      channel.publishEvent('rtc::answer', data: {
        'from': channel.uuid,
        'to': from,
        'sdp': {'sdp': description.sdp, 'type': description.type},
      });
    } else {
      _logger.debug('Got an answer from $from');
    }
  }

  Future<void> handleAnswer(Map signal) async {
    final pc = participants[signal['from']]?.rtc;
    if (pc == null) return;

    final sdpMap = signal['sdp'] as Map;
    await pc.setRemoteDescription(RTCSessionDescription(
        sdpMap['sdp'] as String?, sdpMap['type'] as String?));
  }
}
