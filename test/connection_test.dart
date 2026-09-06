import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:piesocket_channels/channels.dart';

void main() {
  PieSocketOptions v4Options() => PieSocketOptions()..setVersion('4');

  group('Connection — outbound tagging', () {
    test('send() tags system::channel for a secondary channel, not primary',
        () {
      final sent = <String>[];
      final conn =
          Connection.forTesting('room-1', v4Options(), Logger(false), sent.add);

      conn.send('room-1', PieSocketEvent('chat')..setData('hi'));
      conn.send('room-2', PieSocketEvent('chat')..setData('hi'));

      final primaryFrame = json.decode(sent[0]) as Map;
      final secondaryFrame = json.decode(sent[1]) as Map;

      expect(primaryFrame.containsKey('system::channel'), isFalse);
      expect(secondaryFrame['system::channel'], 'room-2');
    });

    test('sendRaw() tags a JSON string the same way', () {
      final sent = <String>[];
      final conn =
          Connection.forTesting('room-1', v4Options(), Logger(false), sent.add);

      conn.sendRaw('room-2', json.encode({'event': 'ping'}));

      final frame = json.decode(sent[0]) as Map;
      expect(frame['system::channel'], 'room-2');
    });

    test('sendRaw() sends non-JSON text verbatim', () {
      final sent = <String>[];
      final conn =
          Connection.forTesting('room-1', v4Options(), Logger(false), sent.add);

      conn.sendRaw('room-2', 'plain text');
      expect(sent[0], 'plain text');
    });
  });

  group('Connection — subscribe control frames', () {
    test('subscribeChannel sends system::subscribe once connected', () {
      final sent = <String>[];
      final conn =
          Connection.forTesting('room-1', v4Options(), Logger(false), sent.add);

      conn.onOpen();
      conn.subscribeChannel('room-2', {'channel': 'room-2', 'uuid': 'u1'});

      expect(sent, hasLength(1));
      final frame = json.decode(sent[0]) as Map;
      expect(frame['event'], 'system::subscribe');
      expect(frame['data']['channel'], 'room-2');
    });

    test(
        'subscribeChannel defers sending until connected, then replays on onOpen',
        () {
      final sent = <String>[];
      final conn =
          Connection.forTesting('room-1', v4Options(), Logger(false), sent.add);

      conn.subscribeChannel('room-2', {'channel': 'room-2', 'uuid': 'u1'});
      expect(sent, isEmpty);

      conn.onOpen();
      expect(sent, hasLength(1));
    });

    test('subscribeChannel resolves on a matching system::subscribe_success',
        () async {
      final conn =
          Connection.forTesting('room-1', v4Options(), Logger(false), (_) {});
      conn.onOpen();

      final future =
          conn.subscribeChannel('room-2', {'channel': 'room-2', 'uuid': 'u1'});
      conn.onMessage(json.encode({
        'event': 'system::subscribe_success',
        'data': {'channel': 'room-2'}
      }));

      await expectLater(future, completes);
    });

    test('subscribeChannel rejects on system::subscribe_error', () async {
      final conn =
          Connection.forTesting('room-1', v4Options(), Logger(false), (_) {});
      conn.onOpen();

      final future =
          conn.subscribeChannel('room-2', {'channel': 'room-2', 'uuid': 'u1'});
      conn.onMessage(json.encode({
        'event': 'system::subscribe_error',
        'data': {'channel': 'room-2', 'error': 'nope'}
      }));

      await expectLater(future, throwsA('nope'));
    });

    test('unsubscribeChannel rejects for the primary channel', () async {
      final conn =
          Connection.forTesting('room-1', v4Options(), Logger(false), (_) {});
      await expectLater(conn.unsubscribeChannel('room-1'), throwsA(anything));
    });
  });

  group('Connection — inbound routing', () {
    test('routes an app frame to the channel named by system::channel', () {
      final conn =
          Connection.forTesting('room-1', v4Options(), Logger(false), (_) {});
      final primary =
          Channel.multiplexed('room-1', v4Options(), Logger(false), conn);
      final secondary =
          Channel.multiplexed('room-2', v4Options(), Logger(false), conn);
      conn.attachChannel('room-1', primary);
      conn.attachChannel('room-2', secondary);

      String? gotOnPrimary;
      String? gotOnSecondary;
      primary.listen('chat', (e) => gotOnPrimary = e.getData());
      secondary.listen('chat', (e) => gotOnSecondary = e.getData());

      conn.onMessage(json.encode(
          {'event': 'chat', 'data': 'hello', 'system::channel': 'room-2'}));

      expect(gotOnPrimary, isNull);
      expect(gotOnSecondary, 'hello');
    });

    test(
        'falls back to the primary channel when no system::channel tag is present',
        () {
      final conn =
          Connection.forTesting('room-1', v4Options(), Logger(false), (_) {});
      final primary =
          Channel.multiplexed('room-1', v4Options(), Logger(false), conn);
      conn.attachChannel('room-1', primary);

      String? got;
      primary.listen('chat', (e) => got = e.getData());
      conn.onMessage(json.encode({'event': 'chat', 'data': 'hi'}));

      expect(got, 'hi');
    });

    test('system::binary carries base64 data through to the channel untouched',
        () {
      final conn =
          Connection.forTesting('room-1', v4Options(), Logger(false), (_) {});
      final primary =
          Channel.multiplexed('room-1', v4Options(), Logger(false), conn);
      conn.attachChannel('room-1', primary);

      String? got;
      primary.listen('system::binary', (e) => got = e.getData());
      final encoded = base64Encode(utf8.encode('hello-bytes'));
      conn.onMessage(json.encode({'event': 'system::binary', 'data': encoded}));

      expect(got, encoded);
      expect(utf8.decode(base64Decode(got!)), 'hello-bytes');
    });
  });

  group('Connection — get_members', () {
    test(
        'requestMembers sends system::get_members and resolves on system::member_list',
        () async {
      final sent = <String>[];
      final conn =
          Connection.forTesting('room-1', v4Options(), Logger(false), sent.add);
      final primary =
          Channel.multiplexed('room-1', v4Options(), Logger(false), conn);
      conn.attachChannel('room-1', primary);

      final future = conn.requestMembers('room-1');
      expect(sent, hasLength(1));
      final frame = json.decode(sent[0]) as Map;
      expect(frame['event'], 'system::get_members');

      conn.onMessage(json.encode({
        'event': 'system::member_list',
        'data': {
          'channel': 'room-1',
          'members': ['a', 'b']
        }
      }));

      final members = await future;
      expect(members, ['a', 'b']);
    });
  });
}
