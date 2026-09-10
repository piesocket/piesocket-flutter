import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';

/// Turns a PieChat-style **call push** into the native incoming-call UI.
///
/// Safe to call from the FCM background isolate (no [PieCall] instance, no
/// Flutter engine) — this is the entry point your `@pragma('vm:entry-point')`
/// `FirebaseMessaging.onBackgroundMessage` handler should forward `call_*`
/// data messages to.
///
/// The server's data payload (see `App\Services\CallPush`):
/// ```
/// { type: 'call_invite' | 'call_cancel',
///   call_uuid, call_id, room, media, is_video,
///   from_id, from_name, from_avatar? }
/// ```
class PieCallPush {
  PieCallPush._();

  static const typeKey = 'type';
  static const invite = 'call_invite';
  static const cancel = 'call_cancel';

  /// True when [data] is a PieCall call push (either kind).
  static bool isCallPush(Map data) =>
      data[typeKey] == invite || data[typeKey] == cancel;

  /// Show the ringing UI ([invite]) or dismiss it ([cancel]).
  ///
  /// A [cancel] is a no-op if this device has already **answered** that call —
  /// the answering device keeps its live call; every other device stops
  /// ringing.
  static Future<void> handleData(Map data, {String appName = 'PieCall'}) async {
    switch (data[typeKey]) {
      case invite:
        await FlutterCallkitIncoming.showCallkitIncoming(params(data, appName));
        break;
      case cancel:
        final uuid = '${data['call_uuid'] ?? data['id'] ?? ''}';
        if (uuid.isEmpty) break;
        if (await _answeredHere(uuid)) break;
        await FlutterCallkitIncoming.endCall(uuid);
        break;
    }
  }

  static Future<bool> _answeredHere(String uuid) async {
    try {
      final active = await FlutterCallkitIncoming.activeCalls();
      return active.any((c) =>
          c.id.toLowerCase() == uuid.toLowerCase() && c.isAccepted);
    } catch (_) {
      return false;
    }
  }

  /// The [CallKitParams] for an incoming call, from a push (or signalling)
  /// payload. Exposed so [PieCall] and tests share one mapping.
  static CallKitParams params(Map data, String appName) {
    final isVideo =
        data['is_video'] == 'true' || data['isVideo'] == true || data['media'] == 'video';
    return CallKitParams(
      id: '${data['call_uuid'] ?? data['id']}',
      nameCaller: '${data['from_name'] ?? data['nameCaller'] ?? 'Call'}',
      appName: appName,
      avatar: (data['from_avatar'] ?? data['avatar'])?.toString(),
      handle: '${data['from_id'] ?? data['handle'] ?? ''}',
      type: isVideo ? 1 : 0,
      duration: 45000,
      missedCallNotification: const NotificationParams(
        showNotification: true,
        isShowCallback: true,
        subtitle: 'Missed call',
        callbackText: 'Call back',
      ),
      extra: <String, dynamic>{
        for (final e in data.entries) '${e.key}': e.value,
      },
      android: const AndroidParams(
        isCustomNotification: true,
        isShowLogo: false,
        ringtonePath: 'system_ringtone_default',
        backgroundColor: '#0F2C1E',
        actionColor: '#12A65C',
        textAccept: 'Accept',
        textDecline: 'Decline',
        incomingCallNotificationChannelName: 'Incoming call',
        missedCallNotificationChannelName: 'Missed call',
        isShowFullLockedScreen: true,
      ),
      ios: const IOSParams(
        handleType: 'generic',
        supportsVideo: true,
        maximumCallGroups: 1,
        maximumCallsPerCallGroup: 1,
        audioSessionMode: 'default',
        audioSessionActive: true,
        supportsDTMF: false,
        supportsHolding: false,
        supportsGrouping: false,
        supportsUngrouping: false,
        ringtonePath: 'system_ringtone_default',
      ),
    );
  }
}
