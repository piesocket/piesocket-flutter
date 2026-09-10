/// Where a call is in its lifecycle.
enum PieCallPhase {
  /// No call.
  idle,

  /// Outgoing call placed, waiting for the peer to pick up.
  dialing,

  /// Incoming call ringing (CallKit / full-screen notification is showing).
  ringing,

  /// Accepted on this side; WebRTC is negotiating.
  connecting,

  /// Media is flowing.
  active,

  /// Call finished — [PieCallSnapshot.endReason] says why. Transient; the next
  /// snapshot is [idle].
  ended,
}

/// Everything the UI needs about the current call. Immutable; a new one is
/// emitted on [PieCall.updates] for every change.
class PieCallSnapshot {
  const PieCallSnapshot({
    this.phase = PieCallPhase.idle,
    this.invite,
    this.outgoing = false,
    this.connectedAt,
    this.endReason,
    this.muted = false,
    this.cameraOn = true,
    this.speakerOn = false,
    this.frontCamera = true,
  });

  final PieCallPhase phase;
  final PieCallInvite? invite;
  final bool outgoing;
  final DateTime? connectedAt;

  /// 'completed' | 'declined' | 'cancelled' | 'missed' | 'failed' | null
  final String? endReason;

  final bool muted;
  final bool cameraOn;
  final bool speakerOn;
  final bool frontCamera;

  bool get isVideo => invite?.video ?? false;

  PieCallSnapshot copyWith({
    PieCallPhase? phase,
    PieCallInvite? invite,
    bool? outgoing,
    DateTime? connectedAt,
    String? endReason,
    bool? muted,
    bool? cameraOn,
    bool? speakerOn,
    bool? frontCamera,
  }) {
    return PieCallSnapshot(
      phase: phase ?? this.phase,
      invite: invite ?? this.invite,
      outgoing: outgoing ?? this.outgoing,
      connectedAt: connectedAt ?? this.connectedAt,
      endReason: endReason ?? this.endReason,
      muted: muted ?? this.muted,
      cameraOn: cameraOn ?? this.cameraOn,
      speakerOn: speakerOn ?? this.speakerOn,
      frontCamera: frontCamera ?? this.frontCamera,
    );
  }
}

/// Identifies one call. `uuid` is the CallKit id (must be a UUID); `callId` is
/// the app's own integer id, passed back to the REST hooks.
class PieCallInvite {
  const PieCallInvite({
    required this.callId,
    required this.uuid,
    required this.room,
    required this.peerId,
    required this.peerName,
    required this.video,
    this.peerAvatar,
  });

  final int callId;
  final String uuid;
  final String room;
  final int peerId;
  final String peerName;
  final bool video;
  final String? peerAvatar;

  /// Build from a `call_invite` signalling payload (or a call push's `extra`).
  factory PieCallInvite.fromMap(Map data) {
    int asInt(Object? v) => v is int ? v : int.tryParse('$v') ?? 0;
    final media = '${data['media'] ?? (data['is_video'] == 'true' || data['isVideo'] == true ? 'video' : 'audio')}';
    return PieCallInvite(
      callId: asInt(data['call_id']),
      uuid: '${data['call_uuid'] ?? data['id'] ?? data['uuid']}',
      room: '${data['room'] ?? 'presence-call-${data['call_id']}'}',
      peerId: asInt(data['from_id']),
      peerName: '${data['from_name'] ?? data['nameCaller'] ?? 'Call'}',
      peerAvatar: (data['from_avatar'] ?? data['avatar'])?.toString(),
      video: media == 'video',
    );
  }
}

/// Tunables for [PieCall].
class PieCallConfig {
  const PieCallConfig({
    this.appName = 'PieCall',
    this.ringtonePath = 'system_ringtone_default',
    this.ringDuration = const Duration(seconds: 45),
    this.iceServers,
  });

  /// Shown on the CallKit / incoming-call UI.
  final String appName;

  /// Android raw resource name / iOS bundle `.caf`; `system_ringtone_default`
  /// uses the OS ringtone.
  final String ringtonePath;

  /// How long an unanswered call rings before it's a miss. Also the CallKit
  /// timeout.
  final Duration ringDuration;

  /// Overrides PieRTC's default STUN list when set.
  final List<Map<String, dynamic>>? iceServers;
}
