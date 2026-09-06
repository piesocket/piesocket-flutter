import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:piesocket_channels/channels.dart';

void main() {
  // ---------------------------------------------------------------------------
  // AuthResolver — synchronous branches (the authEndpoint fetch itself needs
  // an HTTP mock this package has no test infra for yet, matching the
  // pre-existing lack of coverage for Channel.getAuthTokenFromServer()).
  // ---------------------------------------------------------------------------
  group('AuthResolver', () {
    test(
        'resolves synchronously with the configured jwt, ignoring guard status',
        () {
      final opts = PieSocketOptions()..setJwt('configured-jwt');
      String? got;
      AuthResolver.resolve('private-room', 'uuid-1', opts, Logger(false),
          (jwt) => got = jwt, (e) => fail('should not error: $e'));
      expect(got, 'configured-jwt');
    });

    test('resolves synchronously with null for an unguarded channel', () {
      final opts = PieSocketOptions();
      String? got = 'unset';
      var readyCalled = false;
      AuthResolver.resolve('public-room', 'uuid-1', opts, Logger(false), (jwt) {
        readyCalled = true;
        got = jwt;
      }, (e) => fail('should not error: $e'));
      expect(readyCalled, isTrue);
      expect(got, isNull);
    });

    test(
        'errors synchronously for a guarded channel with no jwt and no authEndpoint',
        () {
      final opts = PieSocketOptions();
      Object? error;
      AuthResolver.resolve('private-room', 'uuid-1', opts, Logger(false),
          (jwt) => fail('should not resolve'), (e) => error = e);
      expect(error, isA<PieSocketException>());
    });

    test('forceAuth counts as guarded even without a private- prefix', () {
      final opts = PieSocketOptions()..setForceAuth(true);
      Object? error;
      AuthResolver.resolve('any-room', 'uuid-1', opts, Logger(false),
          (jwt) => fail('should not resolve'), (e) => error = e);
      expect(error, isA<PieSocketException>());
    });

    test('isGuarded matches private- prefix or forceAuth', () {
      final plain = PieSocketOptions();
      final forced = PieSocketOptions()..setForceAuth(true);
      expect(AuthResolver.isGuarded('room', plain), isFalse);
      expect(AuthResolver.isGuarded('private-room', plain), isTrue);
      expect(AuthResolver.isGuarded('room', forced), isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // PieSocketOptions
  // ---------------------------------------------------------------------------
  group('PieSocketOptions', () {
    test('defaults are correct', () {
      final opts = PieSocketOptions();
      expect(opts.getSsl(), true);
      expect(opts.getClusterDomain(), '');
      expect(opts.getClusterId(), '');
      expect(opts.getApiKey(), '');
      expect(opts.getVersion(), '3');
      expect(opts.getEnableLogs(), true);
      expect(opts.getNotifySelf(), 1);
      expect(opts.getPresence(), 0);
      expect(opts.getForceAuth(), false);
      expect(opts.getJwt(), '');
      expect(opts.getUserId(), '');
      expect(opts.getWebSocketEndpoint(), '');
    });

    test('setters and getters work', () {
      final opts = PieSocketOptions();
      opts.setSsl(false);
      opts.setClusterDomain('localhost:4001');
      opts.setClusterId('my-cluster');
      opts.setApiKey('my-api-key');
      opts.setVersion('4');
      opts.setJwt('my-jwt');
      opts.setUserId('user-123');
      opts.setNotifySelf(false);
      opts.setPresence(true);
      opts.setForceAuth(true);
      opts.setEnableLogs(false);

      expect(opts.getSsl(), false);
      expect(opts.getClusterDomain(), 'localhost:4001');
      expect(opts.getClusterId(), 'my-cluster');
      expect(opts.getApiKey(), 'my-api-key');
      expect(opts.getVersion(), '4');
      expect(opts.getJwt(), 'my-jwt');
      expect(opts.getUserId(), 'user-123');
      expect(opts.getNotifySelf(), 0);
      expect(opts.getPresence(), 1);
      expect(opts.getForceAuth(), true);
      expect(opts.getEnableLogs(), false);
    });

    test('setAuthHeaders stores and returns the map', () {
      final opts = PieSocketOptions();
      opts.setAuthHeaders({'Authorization': 'Bearer token', 'X-App': 'test'});
      expect(opts.getAuthHeaders()['Authorization'], 'Bearer token');
      expect(opts.getAuthHeaders()['X-App'], 'test');
    });
  });

  // ---------------------------------------------------------------------------
  // PieSocketEvent
  // ---------------------------------------------------------------------------
  group('PieSocketEvent', () {
    test('creates event with name and empty defaults', () {
      final event = PieSocketEvent('my-event');
      expect(event.getEvent(), 'my-event');
      expect(event.getData(), '');
      expect(event.getMeta(), '');
    });

    test('setData and setMeta work', () {
      final event = PieSocketEvent('test')
        ..setData('hello')
        ..setMeta('world');
      expect(event.getData(), 'hello');
      expect(event.getMeta(), 'world');
    });

    test('setEvent changes the event name', () {
      final event = PieSocketEvent('old')..setEvent('new');
      expect(event.getEvent(), 'new');
    });

    test('toString produces valid JSON with all fields', () {
      final event = PieSocketEvent('greet')
        ..setData('data-val')
        ..setMeta('meta-val');
      final json = event.toString();
      expect(json, contains('"event":"greet"'));
      expect(json, contains('"data":"data-val"'));
      expect(json, contains('"meta":"meta-val"'));
    });
  });

  // ---------------------------------------------------------------------------
  // Channel.buildUrl (static — no WebSocket connection needed)
  // ---------------------------------------------------------------------------
  group('Channel.buildUrl', () {
    const uuid = 'test-uuid-1234';

    test('uses wss:// when ssl is true (default)', () {
      final opts = PieSocketOptions()
        ..setClusterId('demo')
        ..setApiKey('key');
      final url = Channel.buildUrl('room', opts, uuid);
      expect(url, startsWith('wss://'));
    });

    test('uses ws:// when ssl is false', () {
      final opts = PieSocketOptions()
        ..setClusterId('demo')
        ..setApiKey('key')
        ..setSsl(false);
      final url = Channel.buildUrl('room', opts, uuid);
      expect(url, startsWith('ws://'));
    });

    test('uses clusterId.piesocket.com when clusterDomain is empty', () {
      final opts = PieSocketOptions()
        ..setClusterId('us1')
        ..setApiKey('key');
      final url = Channel.buildUrl('room', opts, uuid);
      expect(url, contains('us1.piesocket.com'));
    });

    test('uses clusterDomain when set, ignores clusterId for domain', () {
      final opts = PieSocketOptions()
        ..setClusterId('us1')
        ..setApiKey('key')
        ..setClusterDomain('localhost:4001');
      final url = Channel.buildUrl('room', opts, uuid);
      expect(url, contains('localhost:4001'));
      expect(url, isNot(contains('piesocket.com')));
    });

    test('includes version and channel id in path', () {
      final opts = PieSocketOptions()
        ..setClusterId('demo')
        ..setApiKey('key')
        ..setVersion('3');
      final url = Channel.buildUrl('my-channel', opts, uuid);
      expect(url, contains('/v3/my-channel'));
    });

    test('includes api_key query param', () {
      final opts = PieSocketOptions()
        ..setClusterId('demo')
        ..setApiKey('my-api-key');
      final url = Channel.buildUrl('room', opts, uuid);
      expect(url, contains('api_key=my-api-key'));
    });

    test('includes jwt param when passed', () {
      final opts = PieSocketOptions()
        ..setClusterId('demo')
        ..setApiKey('key');
      final url = Channel.buildUrl('room', opts, uuid, jwt: 'my-jwt-token');
      expect(url, contains('jwt=my-jwt-token'));
    });

    test('includes user param when userId is set', () {
      final opts = PieSocketOptions()
        ..setClusterId('demo')
        ..setApiKey('key')
        ..setUserId('user-42');
      final url = Channel.buildUrl('room', opts, uuid);
      expect(url, contains('user=user-42'));
    });

    test('returns webSocketEndpoint override and skips URL building', () {
      final opts = PieSocketOptions()
        ..setClusterId('demo')
        ..setApiKey('key')
        ..setWebSocketEndpoint('ws://custom.example.com/ws');
      final url = Channel.buildUrl('room', opts, uuid);
      expect(url, 'ws://custom.example.com/ws');
    });
  });

  // ---------------------------------------------------------------------------
  // Channel — listener management
  // ---------------------------------------------------------------------------
  group('Channel listener management', () {
    late Channel channel;

    setUp(() {
      channel = Channel.forTesting('test-room');
    });

    test('listen returns a non-empty listener ID', () {
      final id = channel.listen('evt', (e) {});
      expect(id, isNotEmpty);
    });

    test('multiple listeners on same event get unique IDs', () {
      final id1 = channel.listen('evt', (e) {});
      final id2 = channel.listen('evt', (e) {});
      expect(id1, isNot(equals(id2)));
    });

    test('fireEvent triggers the matching listener', () {
      var called = false;
      channel.listen('ping', (e) => called = true);
      channel.fireEvent(PieSocketEvent('ping'));
      expect(called, isTrue);
    });

    test('fireEvent does not trigger unrelated listeners', () {
      var called = false;
      channel.listen('other', (e) => called = true);
      channel.fireEvent(PieSocketEvent('ping'));
      expect(called, isFalse);
    });

    test('wildcard listener (*) is triggered for any event', () {
      var count = 0;
      channel.listen('*', (e) => count++);
      channel.fireEvent(PieSocketEvent('a'));
      channel.fireEvent(PieSocketEvent('b'));
      expect(count, 2);
    });

    test('listener receives the correct event object', () {
      PieSocketEvent? received;
      channel.listen('greet', (e) => received = e);
      final sent = PieSocketEvent('greet')..setData('hi');
      channel.fireEvent(sent);
      expect(received?.getData(), 'hi');
    });

    test('removeListener stops that listener from firing', () {
      var called = false;
      final id = channel.listen('evt', (e) => called = true);
      channel.removeListener('evt', id);
      channel.fireEvent(PieSocketEvent('evt'));
      expect(called, isFalse);
    });

    test('removeAllListeners removes every listener for an event', () {
      var count = 0;
      channel.listen('evt', (e) => count++);
      channel.listen('evt', (e) => count++);
      channel.removeAllListeners('evt');
      channel.fireEvent(PieSocketEvent('evt'));
      expect(count, 0);
    });

    test('removeAllListeners does not affect other events', () {
      var count = 0;
      channel.listen('keep', (e) => count++);
      channel.listen('remove', (e) {});
      channel.removeAllListeners('remove');
      channel.fireEvent(PieSocketEvent('keep'));
      expect(count, 1);
    });
  });

  // ---------------------------------------------------------------------------
  // Channel.onMessage — inbound message parsing
  // ---------------------------------------------------------------------------
  group('Channel.onMessage', () {
    late Channel channel;

    setUp(() {
      channel = Channel.forTesting('test-room');
    });

    test('fires the named event from a valid JSON message', () {
      PieSocketEvent? received;
      channel.listen('user:joined', (e) => received = e);
      channel.onMessage('{"event":"user:joined","data":"Alice","meta":"{}"}');
      expect(received?.getEvent(), 'user:joined');
      expect(received?.getData(), 'Alice');
    });

    test('fires system:message listener for every message', () {
      final messages = <String>[];
      channel.listen('system:message', (e) => messages.add(e.getData()));
      channel.onMessage('{"event":"test","data":"hello"}');
      channel.onMessage('plain text message');
      expect(messages.length, 2);
    });

    test('handles non-JSON messages without throwing', () {
      expect(() => channel.onMessage('not json at all'), returnsNormally);
    });

    test('fires system:error when message contains error field', () {
      PieSocketEvent? errorEvent;
      channel.listen('system:error', (e) => errorEvent = e);
      channel.onMessage('{"error":"unauthorized"}');
      expect(errorEvent, isNotNull);
      expect(errorEvent?.getData(), 'unauthorized');
    });

    test('parses object data field to JSON string', () {
      PieSocketEvent? received;
      channel.listen('data-event', (e) => received = e);
      channel.onMessage('{"event":"data-event","data":{"key":"value"}}');
      expect(received?.getData(), contains('"key"'));
    });
  });

  // ---------------------------------------------------------------------------
  // Channel — v4 delta presence & multiplexed send (Channel.multiplexed)
  // ---------------------------------------------------------------------------
  group('Channel — v4 delta presence', () {
    PieSocketOptions v4Options() => PieSocketOptions()..setVersion('4');

    test('seeds the roster from system::member_list', () {
      final channel =
          Channel.multiplexed('room-1', v4Options(), Logger(false), null);
      channel.onMessage(
          '{"event":"system::member_list","data":{"members":[{"uuid":"a"},{"uuid":"b"}]}}');
      expect(channel.getAllMembers(), [
        {'uuid': 'a'},
        {'uuid': 'b'}
      ]);
    });

    test(
        'appends a single member on system::member_joined (delta, not whole roster)',
        () {
      final channel =
          Channel.multiplexed('room-1', v4Options(), Logger(false), null);
      channel.onMessage(
          '{"event":"system::member_joined","data":{"member":{"uuid":"a"}}}');
      expect(channel.getAllMembers(), [
        {'uuid': 'a'}
      ]);
    });

    test('does not duplicate a member already on the roster', () {
      final channel =
          Channel.multiplexed('room-1', v4Options(), Logger(false), null);
      channel.onMessage(
          '{"event":"system::member_joined","data":{"member":{"uuid":"a"}}}');
      channel.onMessage(
          '{"event":"system::member_joined","data":{"member":{"uuid":"a"}}}');
      expect(channel.getAllMembers().length, 1);
    });

    test('removes the member on system::member_left', () {
      final channel =
          Channel.multiplexed('room-1', v4Options(), Logger(false), null);
      channel.onMessage(
          '{"event":"system::member_joined","data":{"member":{"uuid":"a"}}}');
      channel.onMessage(
          '{"event":"system::member_joined","data":{"member":{"uuid":"b"}}}');
      channel.onMessage(
          '{"event":"system::member_left","data":{"member":{"uuid":"a"}}}');
      expect(channel.getAllMembers(), [
        {'uuid': 'b'}
      ]);
    });

    test('handles string members (anonymous identities)', () {
      final channel =
          Channel.multiplexed('room-1', v4Options(), Logger(false), null);
      channel.onMessage(
          '{"event":"system::member_joined","data":{"member":"anon:1"}}');
      channel.onMessage(
          '{"event":"system::member_joined","data":{"member":"anon:2"}}');
      channel.onMessage(
          '{"event":"system::member_left","data":{"member":"anon:1"}}');
      expect(channel.getAllMembers(), ['anon:2']);
    });

    test('keeps the v3 whole-roster behaviour when version is not 4', () {
      final channel = Channel.forTesting('room-1');
      channel.onMessage(
          '{"event":"system:member_joined","data":{"members":[{"uuid":"a"},{"uuid":"b"}]}}');
      expect(channel.getAllMembers(), [
        {'uuid': 'a'},
        {'uuid': 'b'}
      ]);
    });
  });

  group('Channel — v4 send path', () {
    PieSocketOptions v4Options() => PieSocketOptions()..setVersion('4');

    test('publish() delegates to the hub for its channel', () {
      final sent = <String, dynamic>{};
      final conn =
          Connection.forTesting('room-1', v4Options(), Logger(false), (_) {});
      final channel =
          Channel.multiplexed('room-2', v4Options(), Logger(false), conn);

      // Swap in a fake hub-send to observe the call without a real socket.
      conn.sendOverride = (data) => sent['raw'] = data;
      channel.publish(PieSocketEvent('chat')
        ..setData('hi')
        ..setMeta('m'));

      final frame = json.decode(sent['raw'] as String) as Map;
      expect(frame['event'], 'chat');
      expect(frame['system::channel'], 'room-2');
    });

    test('publishEvent() sends a structured payload without double-encoding it',
        () {
      final sent = <String>[];
      final conn =
          Connection.forTesting('room-1', v4Options(), Logger(false), sent.add);
      final channel =
          Channel.multiplexed('room-1', v4Options(), Logger(false), conn);

      channel.publishEvent('chat', data: {'text': 'hi'}, meta: {'from': 'a'});

      final frame = json.decode(sent[0]) as Map;
      expect(frame['data'], {'text': 'hi'}); // an object, not a JSON string
      expect(frame['meta'], {'from': 'a'});
    });

    test('refreshMembers() asks the hub to re-sync', () {
      final conn =
          Connection.forTesting('room-1', v4Options(), Logger(false), (_) {});
      final channel =
          Channel.multiplexed('room-1', v4Options(), Logger(false), conn);
      conn.attachChannel('room-1', channel);

      final future = channel.refreshMembers();
      conn.onMessage(json.encode({
        'event': 'system::member_list',
        'data': {
          'channel': 'room-1',
          'members': ['a']
        }
      }));

      expect(future, completion(['a']));
    });

    test('refreshMembers() resolves with the current roster without a hub',
        () async {
      final channel = Channel.forTesting('room-1');
      channel.onMessage(
          '{"event":"system:member_joined","data":{"members":["z"]}}');
      await expectLater(channel.refreshMembers(), completion(['z']));
    });
  });

  // ---------------------------------------------------------------------------
  // PieSocket — validation and room management
  // ---------------------------------------------------------------------------
  group('PieSocket', () {
    test('throws PieSocketException when clusterId is missing', () {
      final opts = PieSocketOptions()..setApiKey('key');
      expect(() => PieSocket(opts), throwsA(isA<PieSocketException>()));
    });

    test('throws PieSocketException when apiKey is missing', () {
      final opts = PieSocketOptions()..setClusterId('demo');
      expect(() => PieSocket(opts), throwsA(isA<PieSocketException>()));
    });

    test('join returns the same Channel instance for the same room ID', () {
      final opts = PieSocketOptions()
        ..setClusterId('demo')
        ..setApiKey('key');
      final ps = PieSocket(opts);
      final r1 = ps.join('room-a');
      final r2 = ps.join('room-a');
      expect(identical(r1, r2), isTrue);
    });

    test('join returns different instances for different room IDs', () {
      final opts = PieSocketOptions()
        ..setClusterId('demo')
        ..setApiKey('key');
      final ps = PieSocket(opts);
      final r1 = ps.join('room-a');
      final r2 = ps.join('room-b');
      expect(identical(r1, r2), isFalse);
    });

    test('getAllRooms reflects all joined rooms', () {
      final opts = PieSocketOptions()
        ..setClusterId('demo')
        ..setApiKey('key');
      final ps = PieSocket(opts);
      ps.join('room-a');
      ps.join('room-b');
      expect(ps.getAllRooms().length, 2);
      expect(ps.getAllRooms().containsKey('room-a'), isTrue);
      expect(ps.getAllRooms().containsKey('room-b'), isTrue);
    });

    test('leave removes the room from getAllRooms', () {
      final opts = PieSocketOptions()
        ..setClusterId('demo')
        ..setApiKey('key');
      final ps = PieSocket(opts);
      ps.join('room-a');
      ps.leave('room-a');
      expect(ps.getAllRooms().containsKey('room-a'), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // PieSocket — v4 multiplexing
  // ---------------------------------------------------------------------------
  group('PieSocket — v4 multiplexing', () {
    PieSocket newV4Client() {
      final opts = PieSocketOptions()
        ..setClusterId('demo')
        ..setApiKey('key')
        ..setVersion('4');
      return PieSocket(opts);
    }

    test(
        'first v4 join() opens the shared connection with this room as primary',
        () {
      final ps = newV4Client();
      final room1 = ps.join('room-1');

      expect(ps.connection, isNotNull);
      expect(ps.connection!.primaryChannelId, 'room-1');
      expect(identical(ps.connection!.channels['room-1'], room1), isTrue);
    });

    test('second v4 join() rides the same connection as a secondary channel',
        () {
      final ps = newV4Client();
      final room1 = ps.join('room-1');
      final room2 = ps.join('room-2');

      expect(identical(room1.hub, room2.hub), isTrue);
      expect(ps.connection!.channels.length, 2);
      expect(room2.subscribeParams, isNotNull);
      expect(room2.subscribeParams!['channel'], 'room-2');
    });

    test(
        'leave() on a secondary channel detaches it without closing the shared socket',
        () {
      final ps = newV4Client();
      ps.join('room-1');
      ps.join('room-2');

      ps.leave('room-2');

      expect(ps.getAllRooms().containsKey('room-2'), isFalse);
      expect(ps.connection, isNotNull);
      expect(ps.connection!.channels.containsKey('room-2'), isFalse);
    });

    test('leave() on the sole channel closes the shared connection', () {
      final ps = newV4Client();
      ps.join('room-1');

      ps.leave('room-1');

      expect(ps.connection, isNull);
      expect(ps.getAllRooms().containsKey('room-1'), isFalse);
    });

    test('leave() on the primary promotes another channel to primary', () {
      final ps = newV4Client();
      ps.join('room-1');
      ps.join('room-2');

      ps.leave('room-1');

      expect(ps.connection, isNotNull);
      expect(ps.connection!.primaryChannelId, 'room-2');
      expect(ps.getAllRooms().containsKey('room-1'), isFalse);
      expect(ps.getAllRooms().containsKey('room-2'), isTrue);
    });

    test('v3 (default) join() never touches connection', () {
      final opts = PieSocketOptions()
        ..setClusterId('demo')
        ..setApiKey('key');
      final ps = PieSocket(opts);
      ps.join('room-a');
      expect(ps.connection, isNull);
    });

    test(
        'join() opens the primary synchronously when a jwt is already configured for a guarded room',
        () {
      final opts = PieSocketOptions()
        ..setClusterId('demo')
        ..setApiKey('key')
        ..setVersion('4')
        ..setJwt('a-jwt');
      final ps = PieSocket(opts);

      final room = ps.join('private-room');

      expect(ps.connection, isNotNull);
      expect(ps.connection!.primaryChannelId, 'private-room');
      expect(identical(room.hub, ps.connection), isTrue);
    });

    test(
        'join() fires system:error (deferred a microtask) when a guarded primary has no jwt route',
        () async {
      final opts = PieSocketOptions()
        ..setClusterId('demo')
        ..setApiKey('key')
        ..setVersion('4')
        ..setForceAuth(true);
      final ps = PieSocket(opts);

      // AuthResolver's "no route to a token" case resolves synchronously,
      // before join() even returns — the error fire is deferred a microtask
      // specifically so a listener attached right after join() still catches
      // it (see PieSocket._fireErrorNextMicrotask).
      final room = ps.join('room-1');
      PieSocketEvent? errorEvent;
      room.listen('system:error', (e) => errorEvent = e);

      expect(ps.connection, isNull);
      expect(errorEvent, isNull); // not yet — still queued as a microtask

      await Future.delayed(Duration.zero);

      expect(errorEvent, isNotNull);
      expect(errorEvent!.getData(), contains('authEndpoint'));
    });
  });
}
