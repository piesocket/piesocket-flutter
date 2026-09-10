import 'package:flutter_test/flutter_test.dart';
import 'package:piesocket_channels/channels.dart';

// PieCall itself touches platform channels (CallKit, WebRTC) that aren't
// available under `flutter test` — same story as pie_rtc_test.dart. What's
// exercisable without a device is the payload plumbing: parsing a signalling /
// push map into an invite, and mapping it to CallKitParams.
void main() {
  group('PieCallInvite.fromMap', () {
    test('reads a call_invite signalling payload', () {
      final inv = PieCallInvite.fromMap({
        'call_id': 42,
        'call_uuid': 'abc-123',
        'room': 'presence-call-42',
        'media': 'video',
        'from_id': 7,
        'from_name': 'Ada',
      });
      expect(inv.callId, 42);
      expect(inv.uuid, 'abc-123');
      expect(inv.room, 'presence-call-42');
      expect(inv.peerId, 7);
      expect(inv.peerName, 'Ada');
      expect(inv.video, isTrue);
    });

    test('reads an FCM data payload (strings, is_video)', () {
      final inv = PieCallInvite.fromMap({
        'type': 'call_invite',
        'call_id': '9',
        'call_uuid': 'u-9',
        'room': 'presence-call-9',
        'is_video': 'false',
        'from_id': '3',
        'from_name': 'Bo',
      });
      expect(inv.callId, 9);
      expect(inv.peerId, 3);
      expect(inv.video, isFalse);
    });

    test('reads a VoIP payload (id / nameCaller / isVideo)', () {
      final inv = PieCallInvite.fromMap({
        'id': 'v-1',
        'call_id': 1,
        'nameCaller': 'Cy',
        'from_id': 5,
        'isVideo': true,
        'room': 'presence-call-1',
      });
      expect(inv.uuid, 'v-1');
      expect(inv.peerName, 'Cy');
      expect(inv.video, isTrue);
    });
  });

  group('PieCallPush', () {
    test('isCallPush recognises both kinds', () {
      expect(PieCallPush.isCallPush({'type': 'call_invite'}), isTrue);
      expect(PieCallPush.isCallPush({'type': 'call_cancel'}), isTrue);
      expect(PieCallPush.isCallPush({'type': 'dm'}), isFalse);
      expect(PieCallPush.isCallPush({}), isFalse);
    });

    test('params maps a payload onto CallKitParams', () {
      final p = PieCallPush.params({
        'call_uuid': 'u-1',
        'from_name': 'Ada',
        'from_id': '7',
        'is_video': 'true',
        'room': 'presence-call-1',
        'type': 'call_invite',
      }, 'PieChat');

      expect(p.id, 'u-1');
      expect(p.nameCaller, 'Ada');
      expect(p.appName, 'PieChat');
      expect(p.handle, '7');
      expect(p.type, 1); // video
      expect(p.extra?['room'], 'presence-call-1');
      expect(p.extra?['type'], 'call_invite');
      expect(p.android?.isShowFullLockedScreen, isTrue);
      expect(p.ios?.supportsVideo, isTrue);
    });

    test('params: audio call is type 0', () {
      final p = PieCallPush.params({'call_uuid': 'u', 'is_video': 'false'}, 'X');
      expect(p.type, 0);
    });
  });

  group('PieCallSnapshot', () {
    test('copyWith patches only what is passed', () {
      const s = PieCallSnapshot(phase: PieCallPhase.ringing);
      final s2 = s.copyWith(muted: true);
      expect(s2.phase, PieCallPhase.ringing);
      expect(s2.muted, isTrue);
      expect(s2.speakerOn, isFalse);
    });

    test('isVideo follows the invite', () {
      final s = PieCallSnapshot(
        phase: PieCallPhase.active,
        invite: PieCallInvite.fromMap({
          'call_id': 1, 'call_uuid': 'u', 'room': 'r', 'media': 'video', 'from_id': 2, 'from_name': 'x',
        }),
      );
      expect(s.isVideo, isTrue);
    });
  });
}
