import 'dart:convert';

import 'misc/logger.dart';
import 'misc/piesocket_exception.dart';
import 'misc/piesocket_options.dart';

import 'package:http/http.dart' as http;

/// Resolves the JWT for a channel — the configured token, or one fetched
/// from the auth endpoint for guarded (`private-`/`forceAuth`) channels.
///
/// [Channel]'s own standalone `connect()` has an older, exception-based
/// version of this same resolution (throw-to-defer, reconnect once the
/// token arrives) that predates this class and is left untouched. This is
/// the callback-based version used by v4's [Connection] (which can't rely
/// on that defer/rethrow — `PieSocket.join()` must stay synchronous even
/// while an auth fetch is in flight).
class AuthResolver {
  static bool isGuarded(String channelId, PieSocketOptions options) {
    if (options.getForceAuth()) return true;
    return channelId.startsWith('private-');
  }

  /// Resolves the JWT for [channelId]. Calls [onReady] with the token (or
  /// null if this channel doesn't need one) — synchronously when a fetch
  /// isn't required, or once an in-flight fetch from `authEndpoint`
  /// completes. Calls [onError] instead if no token is available and none
  /// can be fetched, or if the fetch itself fails.
  static void resolve(
    String channelId,
    String connectionUuid,
    PieSocketOptions options,
    Logger logger,
    void Function(String? jwt) onReady,
    void Function(Object error) onError,
  ) {
    if (options.getJwt().isNotEmpty) {
      onReady(options.getJwt());
      return;
    }

    if (!isGuarded(channelId, options)) {
      onReady(null);
      return;
    }

    if (options.getAuthEndpoint().isEmpty) {
      onError(PieSocketException(
          'Neither JWT, nor authEndpoint is provided for private channel authentication.'));
      return;
    }

    logger.debug('Defer connection: fetching token from authEndpoint');
    _fetchFromServer(channelId, connectionUuid, options).then((jwt) {
      if (jwt == null) {
        onError(PieSocketException('Auth endpoint did not return a token'));
        return;
      }
      options.setJwt(jwt);
      logger.debug('Auth token fetched, resuming connection');
      onReady(jwt);
    }).catchError((e) {
      onError(PieSocketException(
          'Auth Token Response Parsing Error: ${e.toString()}'));
    });
  }

  static Future<String?> _fetchFromServer(
      String channelId, String connectionUuid, PieSocketOptions options) async {
    final headers = {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      ...options.getAuthHeaders(),
    };
    final body = json
        .encode({'channel_name': channelId, 'connection_uuid': connectionUuid});

    final apiResult = await http.post(Uri.parse(options.getAuthEndpoint()),
        headers: headers, body: body);

    final jsonObject = json.decode(apiResult.body) as Map;
    return jsonObject['auth'] as String?;
  }
}
