import 'dart:convert';
import 'dart:io';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:publisher_dart/publisher_dart.dart';
import 'package:test/test.dart';

void main() {
  test('updates draft submission metadata through App Store Connect', () async {
    final requests = <http.Request>[];
    final client = AppStoreConnectClient(
      tokenProvider: const _FakeTokenProvider(),
      httpClient: MockClient((request) async {
        requests.add(request);
        expect(request.headers['authorization'], 'Bearer test-token');

        return switch ((request.method, request.url.path)) {
          ('GET', '/v1/apps') => _jsonResponse({
            'data': [
              {
                'type': 'apps',
                'id': 'app-123',
                'attributes': {'bundleId': 'com.example.app'},
              },
            ],
          }),
          ('GET', '/v1/builds') => _jsonResponse({
            'data': [
              {
                'type': 'builds',
                'id': 'build-123',
                'attributes': {
                  'version': '6502',
                  'processingState': 'VALID',
                  'buildAudienceType': 'APP_STORE_ELIGIBLE',
                },
              },
            ],
          }),
          ('GET', '/v1/apps/app-123/appStoreVersions') => _jsonResponse({
            'data': [
              {
                'type': 'appStoreVersions',
                'id': 'version-123',
                'attributes': {
                  'versionString': '6.5.0',
                  'appVersionState': 'PREPARE_FOR_SUBMISSION',
                },
              },
            ],
          }),
          ('PATCH', '/v1/appStoreVersions/version-123/relationships/build') =>
            http.Response('', 204),
          (
            'GET',
            '/v1/appStoreVersions/version-123/appStoreVersionLocalizations',
          ) =>
            _jsonResponse({
              'data': [
                {
                  'type': 'appStoreVersionLocalizations',
                  'id': 'localization-123',
                  'attributes': {'locale': 'en-US'},
                },
              ],
            }),
          ('PATCH', '/v1/appStoreVersionLocalizations/localization-123') =>
            _jsonResponse({
              'data': {
                'type': 'appStoreVersionLocalizations',
                'id': 'localization-123',
              },
            }),
          _ => http.Response(
            'unexpected ${request.method} ${request.url}',
            500,
          ),
        };
      }),
      delay: (_) async {},
      log: (_) {},
    );

    final result = await client.updateDraftSubmission(
      appId: null,
      bundleId: 'com.example.app',
      version: AppVersion.parse('6.5.0+6502'),
      whatsNewByLocale: {'en-US': 'Internal build'},
    );

    expect(result.appId, 'app-123');
    expect(result.buildId, 'build-123');
    expect(result.appStoreVersionId, 'version-123');
    expect(result.localizationId, 'localization-123');
    expect(result.localizationIdsByLocale, {'en-US': 'localization-123'});

    final appLookup = requests[0];
    expect(
      appLookup.url.queryParameters['filter[bundleId]'],
      'com.example.app',
    );

    final buildLookup = requests[1];
    expect(buildLookup.url.queryParameters['filter[app]'], 'app-123');
    expect(buildLookup.url.queryParameters['filter[version]'], '6502');
    expect(
      buildLookup.url.queryParameters['filter[preReleaseVersion.version]'],
      '6.5.0',
    );
    expect(
      buildLookup.url.queryParameters['filter[buildAudienceType]'],
      'APP_STORE_ELIGIBLE',
    );

    final attachBuild = requests[3];
    expect(jsonDecode(attachBuild.body), {
      'data': {'type': 'builds', 'id': 'build-123'},
    });

    final updateNotes = requests[5];
    expect(jsonDecode(updateNotes.body), {
      'data': {
        'type': 'appStoreVersionLocalizations',
        'id': 'localization-123',
        'attributes': {'whatsNew': 'Internal build'},
      },
    });
  });

  test('creates missing App Store version and localization', () async {
    final paths = <String>[];
    final client = AppStoreConnectClient(
      tokenProvider: const _FakeTokenProvider(),
      httpClient: MockClient((request) async {
        paths.add('${request.method} ${request.url.path}');

        return switch ((request.method, request.url.path)) {
          ('GET', '/v1/builds') => _jsonResponse({
            'data': [
              {
                'type': 'builds',
                'id': 'build-123',
                'attributes': {'processingState': 'VALID'},
              },
            ],
          }),
          ('GET', '/v1/apps/app-123/appStoreVersions') => _jsonResponse({
            'data': <Object>[],
          }),
          ('POST', '/v1/appStoreVersions') => _jsonResponse({
            'data': {
              'type': 'appStoreVersions',
              'id': 'version-123',
              'attributes': {'versionString': '6.5.0'},
            },
          }, statusCode: 201),
          ('PATCH', '/v1/appStoreVersions/version-123/relationships/build') =>
            http.Response('', 204),
          (
            'GET',
            '/v1/appStoreVersions/version-123/appStoreVersionLocalizations',
          ) =>
            _jsonResponse({'data': <Object>[]}),
          ('POST', '/v1/appStoreVersionLocalizations') => _jsonResponse({
            'data': {
              'type': 'appStoreVersionLocalizations',
              'id': 'localization-123',
              'attributes': {'locale': 'en-US'},
            },
          }, statusCode: 201),
          ('PATCH', '/v1/appStoreVersionLocalizations/localization-123') =>
            _jsonResponse({
              'data': {
                'type': 'appStoreVersionLocalizations',
                'id': 'localization-123',
              },
            }),
          _ => http.Response(
            'unexpected ${request.method} ${request.url}',
            500,
          ),
        };
      }),
      delay: (_) async {},
      log: (_) {},
    );

    await client.updateDraftSubmission(
      appId: 'app-123',
      bundleId: 'com.example.app',
      version: AppVersion.parse('6.5.0+6502'),
      whatsNewByLocale: {'en-US': 'Internal build'},
    );

    expect(paths, [
      'GET /v1/builds',
      'GET /v1/apps/app-123/appStoreVersions',
      'POST /v1/appStoreVersions',
      'PATCH /v1/appStoreVersions/version-123/relationships/build',
      'GET /v1/appStoreVersions/version-123/appStoreVersionLocalizations',
      'POST /v1/appStoreVersionLocalizations',
      'PATCH /v1/appStoreVersionLocalizations/localization-123',
    ]);
  });

  test('updates multiple App Store localizations', () async {
    final updateBodies = <Object?>[];
    Object? createLocalizationBody;
    final client = AppStoreConnectClient(
      tokenProvider: const _FakeTokenProvider(),
      httpClient: MockClient((request) async {
        return switch ((request.method, request.url.path)) {
          ('GET', '/v1/builds') => _jsonResponse({
            'data': [
              {
                'type': 'builds',
                'id': 'build-123',
                'attributes': {'processingState': 'VALID'},
              },
            ],
          }),
          ('GET', '/v1/apps/app-123/appStoreVersions') => _jsonResponse({
            'data': [
              {
                'type': 'appStoreVersions',
                'id': 'version-123',
                'attributes': {'versionString': '6.5.0'},
              },
            ],
          }),
          ('PATCH', '/v1/appStoreVersions/version-123/relationships/build') =>
            http.Response('', 204),
          (
            'GET',
            '/v1/appStoreVersions/version-123/appStoreVersionLocalizations',
          ) =>
            request.url.queryParameters['filter[locale]'] == 'en-US'
                ? _jsonResponse({
                    'data': [
                      {
                        'type': 'appStoreVersionLocalizations',
                        'id': 'localization-en',
                        'attributes': {'locale': 'en-US'},
                      },
                    ],
                  })
                : _jsonResponse({'data': <Object>[]}),
          ('POST', '/v1/appStoreVersionLocalizations') => () {
            createLocalizationBody = jsonDecode(request.body);
            return _jsonResponse({
              'data': {
                'type': 'appStoreVersionLocalizations',
                'id': 'localization-es',
                'attributes': {'locale': 'es-MX'},
              },
            }, statusCode: 201);
          }(),
          ('PATCH', '/v1/appStoreVersionLocalizations/localization-en') => () {
            updateBodies.add(jsonDecode(request.body));
            return _jsonResponse({
              'data': {
                'type': 'appStoreVersionLocalizations',
                'id': 'localization-en',
              },
            });
          }(),
          ('PATCH', '/v1/appStoreVersionLocalizations/localization-es') => () {
            updateBodies.add(jsonDecode(request.body));
            return _jsonResponse({
              'data': {
                'type': 'appStoreVersionLocalizations',
                'id': 'localization-es',
              },
            });
          }(),
          _ => http.Response(
            'unexpected ${request.method} ${request.url}',
            500,
          ),
        };
      }),
      delay: (_) async {},
      log: (_) {},
    );

    final result = await client.updateDraftSubmission(
      appId: 'app-123',
      bundleId: 'com.example.app',
      version: AppVersion.parse('6.5.0+6502'),
      whatsNewByLocale: {'es-MX': 'Notas internas', 'en-US': 'Internal notes'},
    );

    expect(result.localizationIdsByLocale, {
      'en-US': 'localization-en',
      'es-MX': 'localization-es',
    });
    expect(createLocalizationBody, {
      'data': {
        'type': 'appStoreVersionLocalizations',
        'attributes': {'locale': 'es-MX', 'whatsNew': 'Notas internas'},
        'relationships': {
          'appStoreVersion': {
            'data': {'type': 'appStoreVersions', 'id': 'version-123'},
          },
        },
      },
    });
    expect(updateBodies, [
      {
        'data': {
          'type': 'appStoreVersionLocalizations',
          'id': 'localization-en',
          'attributes': {'whatsNew': 'Internal notes'},
        },
      },
      {
        'data': {
          'type': 'appStoreVersionLocalizations',
          'id': 'localization-es',
          'attributes': {'whatsNew': 'Notas internas'},
        },
      },
    ]);
  });

  test('creates individual and team API JWT payloads', () async {
    final directory = await Directory.systemTemp.createTemp(
      'publisher_dart_asc_test_',
    );
    addTearDown(() => directory.delete(recursive: true));

    final keyFile = File('${directory.path}/AuthKey_TEST.p8');
    await keyFile.writeAsString(_testEcPrivateKey);

    final individualToken = AppStoreConnectCredentials(
      keyId: 'INDIVIDUAL',
      privateKeyFile: keyFile,
    ).createToken();
    final individualJwt = JWT.decode(individualToken);

    expect(individualJwt.header?['kid'], 'INDIVIDUAL');
    expect(individualJwt.payload['aud'], 'appstoreconnect-v1');
    expect(individualJwt.payload['sub'], 'user');
    expect(individualJwt.payload, isNot(contains('iss')));

    final teamToken = AppStoreConnectCredentials(
      keyId: 'TEAM',
      issuerId: 'issuer-id',
      privateKeyFile: keyFile,
    ).createToken();
    final teamJwt = JWT.decode(teamToken);

    expect(teamJwt.header?['kid'], 'TEAM');
    expect(teamJwt.payload['aud'], 'appstoreconnect-v1');
    expect(teamJwt.payload['iss'], 'issuer-id');
    expect(teamJwt.payload, isNot(contains('sub')));
  });
}

http.Response _jsonResponse(Object body, {int statusCode = 200}) {
  return http.Response(
    jsonEncode(body),
    statusCode,
    headers: {'content-type': 'application/json'},
  );
}

final class _FakeTokenProvider implements AppStoreConnectTokenProvider {
  const _FakeTokenProvider();

  @override
  String createToken() => 'test-token';
}

const _testEcPrivateKey = '''
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgevZzL1gdAFr88hb2
OF/2NxApJCzGCEDdfSp6VQO30hyhRANCAAQRWz+jn65BtOMvdyHKcvjBeBSDZH2r
1RTwjmYSi9R/zpBnuQ4EiMnCqfMPWiZqB4QdbAd0E7oH50VpuZ1P087G
-----END PRIVATE KEY-----
''';
