import 'package:flutter_test/flutter_test.dart';
import 'package:piesocket_channels/channels.dart';

void main() {
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
}
