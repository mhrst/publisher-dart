import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:publisher_dart/src/app_store_connect_auth.dart';
import 'package:publisher_dart/src/app_version.dart';

final class AppStoreConnectClient {
  final AppStoreConnectCredentials credentials;
  final http.Client _client;
  final Uri _baseUri;

  AppStoreConnectClient({
    required this.credentials,
    http.Client? client,
    Uri? baseUri,
  }) : _client = client ?? http.Client(),
       _baseUri = baseUri ?? Uri.parse('https://api.appstoreconnect.apple.com');

  Future<String?> findProcessedBuildId({
    required String appId,
    required AppVersion version,
  }) async {
    final body = await _getJson(
      _uri('/v1/builds', {
        'filter[app]': appId,
        'filter[version]': version.buildNumber.toString(),
        'filter[preReleaseVersion.version]': version.buildName,
        'filter[processingState]': 'VALID',
        'sort': '-uploadedDate',
        'limit': '1',
      }),
    );

    final data = body['data'];
    if (data is! List || data.isEmpty) {
      return null;
    }

    final first = data.first;
    if (first is! Map<String, dynamic>) {
      return null;
    }
    final id = first['id'];
    return id is String ? id : null;
  }

  Future<String> waitForProcessedBuildId({
    required String appId,
    required AppVersion version,
    required Duration timeout,
    required Duration pollInterval,
    void Function(String message)? log,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final buildId = await findProcessedBuildId(
        appId: appId,
        version: version,
      );
      if (buildId != null) {
        return buildId;
      }

      log?.call(
        'Waiting for App Store Connect to process ${version.buildName} '
        '(${version.buildNumber})...',
      );
      await Future<void>.delayed(pollInterval);
    }

    throw TimeoutException(
      'Timed out waiting for TestFlight build ${version.buildName} '
      '(${version.buildNumber}) to finish processing.',
      timeout,
    );
  }

  Future<void> upsertBetaBuildLocalization({
    required String buildId,
    required String locale,
    required String whatsNew,
  }) async {
    final existingId = await _findBetaBuildLocalizationId(
      buildId: buildId,
      locale: locale,
    );

    if (existingId == null) {
      await _postJson(_uri('/v1/betaBuildLocalizations'), {
        'data': {
          'type': 'betaBuildLocalizations',
          'attributes': {'locale': locale, 'whatsNew': whatsNew},
          'relationships': {
            'build': {
              'data': {'type': 'builds', 'id': buildId},
            },
          },
        },
      });
      return;
    }

    await _patchJson(_uri('/v1/betaBuildLocalizations/$existingId'), {
      'data': {
        'type': 'betaBuildLocalizations',
        'id': existingId,
        'attributes': {'whatsNew': whatsNew},
      },
    });
  }

  void close() {
    _client.close();
  }

  Future<String?> _findBetaBuildLocalizationId({
    required String buildId,
    required String locale,
  }) async {
    final body = await _getJson(
      _uri('/v1/betaBuildLocalizations', {
        'filter[build]': buildId,
        'filter[locale]': locale,
        'limit': '1',
      }),
    );

    final data = body['data'];
    if (data is! List || data.isEmpty) {
      return null;
    }

    final first = data.first;
    if (first is! Map<String, dynamic>) {
      return null;
    }
    final id = first['id'];
    return id is String ? id : null;
  }

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    final response = await _client.get(uri, headers: await _headers());
    return _decodeResponse('GET', uri, response);
  }

  Future<Map<String, dynamic>> _postJson(
    Uri uri,
    Map<String, Object?> body,
  ) async {
    final response = await _client.post(
      uri,
      headers: await _headers(jsonBody: true),
      body: jsonEncode(body),
    );
    return _decodeResponse('POST', uri, response);
  }

  Future<Map<String, dynamic>> _patchJson(
    Uri uri,
    Map<String, Object?> body,
  ) async {
    final response = await _client.patch(
      uri,
      headers: await _headers(jsonBody: true),
      body: jsonEncode(body),
    );
    return _decodeResponse('PATCH', uri, response);
  }

  Future<Map<String, String>> _headers({bool jsonBody = false}) async {
    return {
      'Authorization': 'Bearer ${await credentials.createJwt()}',
      'Accept': 'application/json',
      if (jsonBody) 'Content-Type': 'application/json',
    };
  }

  Map<String, dynamic> _decodeResponse(
    String method,
    Uri uri,
    http.Response response,
  ) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        'App Store Connect API $method ${uri.path} failed with '
        'HTTP ${response.statusCode}: ${_errorMessage(response.body)}',
      );
    }

    if (response.body.trim().isEmpty) {
      return const {};
    }

    final decoded = jsonDecode(response.body);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }

    throw FormatException(
      'Expected App Store Connect API response to be a JSON object.',
      response.body,
    );
  }

  Uri _uri(String path, [Map<String, String>? queryParameters]) {
    return _baseUri.replace(path: path, queryParameters: queryParameters);
  }

  String _errorMessage(String body) {
    if (body.trim().isEmpty) {
      return 'empty response body';
    }

    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final errors = decoded['errors'];
        if (errors is List && errors.isNotEmpty) {
          return errors
              .whereType<Map<String, dynamic>>()
              .map((error) {
                final title = error['title'];
                final detail = error['detail'];
                return [
                  if (title is String) title,
                  if (detail is String) detail,
                ].join(': ');
              })
              .where((message) => message.isNotEmpty)
              .join('; ');
        }
      }
    } on FormatException {
      // Fall through to the raw body below.
    }

    return body;
  }
}
