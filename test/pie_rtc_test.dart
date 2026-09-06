import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:piesocket_channels/channels.dart';

// PieRTC methods that call flutter_webrtc's createPeerConnection (shareVideo,
// createAnswer, addIceCandidate, handleAnswer) need a real native platform
// channel — under plain `flutter test` that throws "Binding has not yet been
// initialized" rather than hanging, but there's nothing meaningful to assert
// on without mocking the platform channel, which is out of scope here. These
// tests cover what's genuinely exercisable without native WebRTC: the pure
// signalling (publish calls) and the Channel-level rtc:: dispatch/guards.
void main() {
  PieSocketOptions v4Options() => PieSocketOptions()..setVersion('4');

  group('PieRTC — signalling that does not touch native WebRTC', () {
    test(
        'a no-media room (video/audio both false) requests peer video on construction',
        () {
      final sent = <String>[];
      final conn =
          Connection.forTesting('room-1', v4Options(), Logger(false), sent.add);
      final channel =
          Channel.multiplexed('room-1', v4Options(), Logger(false), conn);
      channel.uuid = 'me';

      channel.pieRTC = PieRTC(
          channel, PieRTCOptions(video: false, audio: false), Logger(false));

      expect(sent, hasLength(1));
      final frame = json.decode(sent[0]) as Map;
      expect(frame['event'], 'rtc::broadcaster');
      expect(frame['data']['from'], 'me');
    });

    test('shouldBroadcast: false requests as a watcher instead', () {
      final sent = <String>[];
      final conn =
          Connection.forTesting('room-1', v4Options(), Logger(false), sent.add);
      final channel =
          Channel.multiplexed('room-1', v4Options(), Logger(false), conn);
      channel.uuid = 'me';

      channel.pieRTC = PieRTC(
        channel,
        PieRTCOptions(video: false, audio: false, shouldBroadcast: false),
        Logger(false),
      );

      final frame = json.decode(sent[0]) as Map;
      expect(frame['event'], 'rtc::watcher');
    });

    test(
        'removeParticipant fires onParticipantLeft and clears the participant map',
        () {
      String? left;
      final conn =
          Connection.forTesting('room-1', v4Options(), Logger(false), (_) {});
      final channel =
          Channel.multiplexed('room-1', v4Options(), Logger(false), conn);
      channel.uuid = 'me';
      final pieRTC = PieRTC(
        channel,
        PieRTCOptions(
          video: false,
          audio: false,
          onParticipantLeft: (uuid) => left = uuid,
        ),
        Logger(false),
      );

      pieRTC.removeParticipant('peer-1');

      expect(left, 'peer-1');
      expect(pieRTC.participants.containsKey('peer-1'), isFalse);
    });
  });

  group('Channel — rtc:: dispatch', () {
    test(
        'routes rtc::broadcaster from a peer to requestOfferFromPeer (re-publishes a request)',
        () {
      final sent = <String>[];
      final conn =
          Connection.forTesting('room-1', v4Options(), Logger(false), sent.add);
      final channel =
          Channel.multiplexed('room-1', v4Options(), Logger(false), conn);
      channel.uuid = 'me';
      channel.pieRTC = PieRTC(
          channel, PieRTCOptions(video: false, audio: false), Logger(false));
      sent.clear(); // drop the constructor's own initial broadcaster frame

      channel.onMessage(json.encode({
        'event': 'rtc::broadcaster',
        'data': {'from': 'peer-1'}
      }));

      expect(sent, hasLength(1));
      final frame = json.decode(sent[0]) as Map;
      expect(frame['event'], 'rtc::request');
    });

    test('ignores rtc::broadcaster echoed back from itself', () {
      final sent = <String>[];
      final conn =
          Connection.forTesting('room-1', v4Options(), Logger(false), sent.add);
      final channel =
          Channel.multiplexed('room-1', v4Options(), Logger(false), conn);
      channel.uuid = 'me';
      channel.pieRTC = PieRTC(
          channel, PieRTCOptions(video: false, audio: false), Logger(false));
      sent.clear();

      channel.onMessage(json.encode({
        'event': 'rtc::broadcaster',
        'data': {'from': 'me'}
      }));

      expect(sent, isEmpty);
    });

    test('rtc::stopped_screen from a peer calls onScreenSharingStopped', () {
      String? stoppedUuid;
      String? stoppedStreamId;
      final conn =
          Connection.forTesting('room-1', v4Options(), Logger(false), (_) {});
      final channel =
          Channel.multiplexed('room-1', v4Options(), Logger(false), conn);
      channel.uuid = 'me';
      channel.pieRTC = PieRTC(
        channel,
        PieRTCOptions(
          video: false,
          audio: false,
          onScreenSharingStopped: (uuid, streamId) {
            stoppedUuid = uuid;
            stoppedStreamId = streamId;
          },
        ),
        Logger(false),
      );

      channel.onMessage(json.encode({
        'event': 'rtc::stopped_screen',
        'data': {'from': 'peer-1', 'streamId': 'stream-abc'}
      }));

      expect(stoppedUuid, 'peer-1');
      expect(stoppedStreamId, 'stream-abc');
    });

    test(
        'does not throw on an rtc:: event for a channel with no PieRTC attached',
        () {
      final conn =
          Connection.forTesting('room-1', v4Options(), Logger(false), (_) {});
      final channel =
          Channel.multiplexed('room-1', v4Options(), Logger(false), conn);
      channel.uuid = 'me';

      expect(
        () => channel.onMessage(json.encode({
          'event': 'rtc::broadcaster',
          'data': {'from': 'peer-1'}
        })),
        returnsNormally,
      );
    });

    test('removes the PieRTC participant on system::member_left', () {
      String? left;
      final conn =
          Connection.forTesting('room-1', v4Options(), Logger(false), (_) {});
      final channel =
          Channel.multiplexed('room-1', v4Options(), Logger(false), conn);
      channel.uuid = 'me';
      channel.pieRTC = PieRTC(
        channel,
        PieRTCOptions(
            video: false,
            audio: false,
            onParticipantLeft: (uuid) => left = uuid),
        Logger(false),
      );

      channel.onMessage(json.encode({
        'event': 'system::member_left',
        'data': {
          'member': {'uuid': 'peer-1'},
          'count': 0
        }
      }));

      expect(left, 'peer-1');
    });
  });

  group('PieSocket.join() — PieRTC wiring', () {
    test('video/audio/pieRTC flags are all valid triggers for attaching PieRTC',
        () {
      final opts = PieSocketOptions()
        ..setClusterId('demo')
        ..setApiKey('key')
        ..setVersion('4');
      final ps = PieSocket(opts);

      final room = ps.join('watch-only-room', pieRTC: true);
      expect(room.pieRTC, isNotNull);
    });

    test('a plain join() (no video/audio/pieRTC) never attaches PieRTC', () {
      final opts = PieSocketOptions()
        ..setClusterId('demo')
        ..setApiKey('key')
        ..setVersion('4');
      final ps = PieSocket(opts);

      final room = ps.join('plain-room');
      expect(room.pieRTC, isNull);
    });

    test(
        'a PieRTC room under v3 (default version) is not supported and pieRTC stays null',
        () {
      final opts = PieSocketOptions()
        ..setClusterId('demo')
        ..setApiKey('key');
      final ps = PieSocket(opts);

      final room = ps.join('video-room', video: true);
      expect(room.pieRTC, isNull);
    });
  });
}
