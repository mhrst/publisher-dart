import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:http/http.dart' as http;
import 'package:publisher_dart/src/app_version.dart';

typedef Delay = Future<void> Function(Duration duration);

abstract interface class AppStoreConnectTokenProvider {
  String createToken();
}

final class AppStoreConnectCredentials implements AppStoreConnectTokenProvider {
  final String keyId;
  final File privateKeyFile;
  final String? issuerId;
  final Duration tokenLifetime;

  const AppStoreConnectCredentials({
    required this.keyId,
    required this.privateKeyFile,
    this.issuerId,
    this.tokenLifetime = const Duration(minutes: 10),
  });

  @override
  String createToken() {
    final trimmedKeyId = keyId.trim();
    if (trimmedKeyId.isEmpty) {
      throw const FormatException('Missing App Store Connect API key ID.');
    }
    if (!privateKeyFile.existsSync()) {
      throw FileSystemException(
        'Missing App Store Connect API private key.',
        privateKeyFile.path,
      );
    }

    final trimmedIssuerId = issuerId?.trim();
    final payload = <String, Object>{
      'aud': 'appstoreconnect-v1',
      if (trimmedIssuerId == null || trimmedIssuerId.isEmpty)
        'sub': 'user'
      else
        'iss': trimmedIssuerId,
    };
    final jwt = JWT(payload, header: {'kid': trimmedKeyId, 'typ': 'JWT'});

    return jwt.sign(
      ECPrivateKey(privateKeyFile.readAsStringSync()),
      algorithm: JWTAlgorithm.ES256,
      expiresIn: tokenLifetime,
    );
  }
}

final class AppStoreConnectClient {
  final AppStoreConnectTokenProvider tokenProvider;
  final http.Client _httpClient;
  final Uri baseUri;
  final Delay delay;
  final void Function(String line) log;

  AppStoreConnectClient({
    required this.tokenProvider,
    http.Client? httpClient,
    Uri? baseUri,
    Delay? delay,
    this.log = print,
  }) : _httpClient = httpClient ?? http.Client(),
       baseUri = baseUri ?? Uri.parse('https://api.appstoreconnect.apple.com'),
       delay = delay ?? Future<void>.delayed;

  void close() {
    _httpClient.close();
  }

  Future<AppStoreDraftUpdateResult> updateDraftSubmission({
    required String bundleId,
    required String? appId,
    required AppVersion version,
    required Map<String, String> whatsNewByLocale,
    Duration buildPollTimeout = const Duration(minutes: 30),
    Duration buildPollInterval = const Duration(seconds: 30),
  }) async {
    final resolvedAppId = await resolveAppId(appId: appId, bundleId: bundleId);
    final build = await waitForProcessedBuild(
      appId: resolvedAppId,
      version: version,
      timeout: buildPollTimeout,
      interval: buildPollInterval,
    );
    final appStoreVersion = await findOrCreateAppStoreVersion(
      appId: resolvedAppId,
      versionString: version.buildName,
    );

    await attachBuild(appStoreVersionId: appStoreVersion.id, buildId: build.id);

    final localizationIdsByLocale = <String, String>{};
    final whatsNewEntries =
        whatsNewByLocale.entries
            .where((entry) => entry.value.isNotEmpty)
            .toList()
          ..sort((a, b) => a.key.compareTo(b.key));
    for (final entry in whatsNewEntries) {
      final localization = await findOrCreateLocalization(
        appStoreVersionId: appStoreVersion.id,
        locale: entry.key,
        whatsNew: entry.value,
      );
      await updateWhatsNew(
        localizationId: localization.id,
        whatsNew: entry.value,
      );
      localizationIdsByLocale[entry.key] = localization.id;
    }

    return AppStoreDraftUpdateResult(
      appId: resolvedAppId,
      buildId: build.id,
      appStoreVersionId: appStoreVersion.id,
      localizationIdsByLocale: localizationIdsByLocale,
    );
  }

  Future<String> resolveAppId({
    required String? appId,
    required String bundleId,
  }) async {
    final trimmedAppId = appId?.trim();
    if (trimmedAppId != null && trimmedAppId.isNotEmpty) {
      return trimmedAppId;
    }

    final trimmedBundleId = bundleId.trim();
    if (trimmedBundleId.isEmpty) {
      throw const FormatException(
        'Missing iOS bundle ID for App Store Connect app lookup.',
      );
    }

    log('Finding App Store Connect app for bundle ID $trimmedBundleId.');
    final response = await _getJson(
      '/v1/apps',
      query: {
        'filter[bundleId]': trimmedBundleId,
        'fields[apps]': 'bundleId,name',
        'limit': '2',
      },
    );
    final apps = _dataList(response);
    if (apps.isEmpty) {
      throw StateError(
        'App Store Connect did not return an app for bundle ID '
        '$trimmedBundleId.',
      );
    }
    if (apps.length > 1) {
      throw StateError(
        'App Store Connect returned multiple apps for bundle ID '
        '$trimmedBundleId.',
      );
    }
    return _resourceId(apps.single, 'app');
  }

  Future<AppStoreBuild> waitForProcessedBuild({
    required String appId,
    required AppVersion version,
    required Duration timeout,
    required Duration interval,
  }) async {
    final deadline = DateTime.now().add(timeout);

    while (true) {
      final build = await findUploadedBuild(appId: appId, version: version);
      if (build == null) {
        log(
          'Waiting for build ${version.buildNumber} (${version.buildName}) to '
          'appear in App Store Connect.',
        );
      } else {
        switch (build.processingState) {
          case 'VALID':
            log('Build ${build.id} is processed and valid.');
            return build;
          case 'FAILED':
          case 'INVALID':
            throw StateError(
              'App Store Connect build ${build.id} is '
              '${build.processingState}.',
            );
          default:
            log(
              'Waiting for build ${build.id} to process '
              '(${build.processingState}).',
            );
        }
      }

      if (!DateTime.now().isBefore(deadline)) {
        throw TimeoutException(
          'Timed out waiting for App Store Connect build '
          '${version.buildNumber} (${version.buildName}) to process.',
          timeout,
        );
      }
      await delay(interval);
    }
  }

  Future<AppStoreBuild?> findUploadedBuild({
    required String appId,
    required AppVersion version,
  }) async {
    final response = await _getJson(
      '/v1/builds',
      query: {
        'filter[app]': appId,
        'filter[version]': version.buildNumber.toString(),
        'filter[preReleaseVersion.version]': version.buildName,
        'filter[preReleaseVersion.platform]': 'IOS',
        'filter[buildAudienceType]': 'APP_STORE_ELIGIBLE',
        'fields[builds]':
            'version,processingState,uploadedDate,buildAudienceType',
        'limit': '10',
        'sort': '-uploadedDate',
      },
    );
    final builds = _dataList(response);
    if (builds.isEmpty) {
      return null;
    }
    return AppStoreBuild.fromJson(builds.first);
  }

  Future<AppStoreVersion> findOrCreateAppStoreVersion({
    required String appId,
    required String versionString,
    bool reuseExistingDraft = false,
  }) async {
    final response = await _getJson(
      '/v1/apps/$appId/appStoreVersions',
      query: {
        'filter[platform]': 'IOS',
        'filter[versionString]': versionString,
        'fields[appStoreVersions]':
            'platform,versionString,appVersionState,appStoreState',
        'limit': '2',
      },
    );
    final versions = _dataList(response);
    if (versions.isNotEmpty) {
      final version = AppStoreVersion.fromJson(versions.first);
      log(
        'Using App Store version ${version.id} for ${version.versionString}.',
      );
      return version;
    }

    if (reuseExistingDraft) {
      final draft = await findEditableDraftAppStoreVersion(appId: appId);
      if (draft != null) {
        if (draft.versionString == versionString) {
          log(
            'Using App Store version draft ${draft.id} for '
            '${draft.versionString}.',
          );
          return draft;
        }
        return updateAppStoreVersionString(
          appStoreVersionId: draft.id,
          versionString: versionString,
          previousVersionString: draft.versionString,
        );
      }
    }

    log('Creating App Store version draft $versionString.');
    final created = await _postJson(
      '/v1/appStoreVersions',
      body: {
        'data': {
          'type': 'appStoreVersions',
          'attributes': {
            'platform': 'IOS',
            'versionString': versionString,
            'releaseType': 'MANUAL',
          },
          'relationships': {
            'app': {
              'data': {'type': 'apps', 'id': appId},
            },
          },
        },
      },
    );
    return AppStoreVersion.fromJson(_dataObject(created));
  }

  Future<AppStoreVersion?> findEditableDraftAppStoreVersion({
    required String appId,
  }) async {
    final response = await _getJson(
      '/v1/apps/$appId/appStoreVersions',
      query: {
        'filter[platform]': 'IOS',
        'fields[appStoreVersions]':
            'platform,versionString,appVersionState,appStoreState',
        'limit': '200',
      },
    );
    final versions = _dataList(response).map(AppStoreVersion.fromJson);
    final drafts = [
      for (final version in versions)
        if (version.isEditableDraft) version,
    ];
    if (drafts.isEmpty) {
      return null;
    }
    if (drafts.length > 1) {
      throw StateError(
        'App Store Connect returned multiple editable App Store version '
        'drafts: ${drafts.map((draft) => draft.id).join(', ')}.',
      );
    }
    return drafts.single;
  }

  Future<AppStoreVersion> updateAppStoreVersionString({
    required String appStoreVersionId,
    required String versionString,
    required String? previousVersionString,
  }) async {
    final previous = previousVersionString == null
        ? ''
        : ' from $previousVersionString';
    log(
      'Updating App Store version draft $appStoreVersionId$previous to '
      '$versionString.',
    );
    final response = await _patchJson(
      '/v1/appStoreVersions/$appStoreVersionId',
      body: {
        'data': {
          'type': 'appStoreVersions',
          'id': appStoreVersionId,
          'attributes': {'versionString': versionString},
        },
      },
    );
    if (response == null) {
      return AppStoreVersion(
        id: appStoreVersionId,
        versionString: versionString,
        appVersionState: null,
        appStoreState: null,
      );
    }
    return AppStoreVersion.fromJson(_dataObject(response));
  }

  Future<void> attachBuild({
    required String appStoreVersionId,
    required String buildId,
  }) async {
    log('Attaching build $buildId to App Store version $appStoreVersionId.');
    await _patchJson(
      '/v1/appStoreVersions/$appStoreVersionId/relationships/build',
      body: {
        'data': {'type': 'builds', 'id': buildId},
      },
    );
  }

  Future<AppStoreVersionLocalization> findOrCreateLocalization({
    required String appStoreVersionId,
    required String locale,
    required String whatsNew,
  }) async {
    final localization = await findLocalization(
      appStoreVersionId: appStoreVersionId,
      locale: locale,
    );
    if (localization != null) {
      return localization;
    }

    log('Creating $locale App Store version localization.');
    final created = await _postJson(
      '/v1/appStoreVersionLocalizations',
      body: {
        'data': {
          'type': 'appStoreVersionLocalizations',
          'attributes': {'locale': locale, 'whatsNew': whatsNew},
          'relationships': {
            'appStoreVersion': {
              'data': {'type': 'appStoreVersions', 'id': appStoreVersionId},
            },
          },
        },
      },
    );
    return AppStoreVersionLocalization.fromJson(_dataObject(created));
  }

  Future<AppStoreVersionLocalization?> findLocalization({
    required String appStoreVersionId,
    required String locale,
  }) async {
    final response = await _getJson(
      '/v1/appStoreVersions/$appStoreVersionId/appStoreVersionLocalizations',
      query: {
        'filter[locale]': locale,
        'fields[appStoreVersionLocalizations]': 'locale,whatsNew',
        'limit': '2',
      },
    );
    final localizations = _dataList(response);
    if (localizations.isEmpty) {
      return null;
    }
    return AppStoreVersionLocalization.fromJson(localizations.first);
  }

  Future<void> updateWhatsNew({
    required String localizationId,
    required String whatsNew,
  }) async {
    log(
      'Updating App Store what\'s-new text for localization $localizationId.',
    );
    await _patchJson(
      '/v1/appStoreVersionLocalizations/$localizationId',
      body: {
        'data': {
          'type': 'appStoreVersionLocalizations',
          'id': localizationId,
          'attributes': {'whatsNew': whatsNew},
        },
      },
    );
  }

  Future<Map<String, Object?>> _getJson(
    String path, {
    Map<String, String>? query,
  }) async {
    final response = await _send('GET', path, query: query);
    return _responseJson(response);
  }

  Future<Map<String, Object?>> _postJson(
    String path, {
    required Map<String, Object?> body,
  }) async {
    final response = await _send('POST', path, body: body);
    return _responseJson(response);
  }

  Future<Map<String, Object?>?> _patchJson(
    String path, {
    required Map<String, Object?> body,
  }) async {
    final response = await _send('PATCH', path, body: body);
    if (response.body.trim().isEmpty) {
      return null;
    }
    return _responseJson(response);
  }

  Future<http.Response> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, Object?>? body,
  }) async {
    final request = http.Request(method, _uri(path, query));
    request.headers.addAll({
      'accept': 'application/json',
      'authorization': 'Bearer ${tokenProvider.createToken()}',
      if (body != null) 'content-type': 'application/json',
    });
    if (body != null) {
      request.body = jsonEncode(body);
    }

    final streamed = await _httpClient.send(request);
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        'App Store Connect $method ${request.url.path} failed with HTTP '
        '${response.statusCode}: ${_errorMessage(response.body)}',
      );
    }
    return response;
  }

  Uri _uri(String path, Map<String, String>? query) {
    final cleanPath = path.startsWith('/') ? path.substring(1) : path;
    final basePath = baseUri.path.endsWith('/')
        ? baseUri.path.substring(0, baseUri.path.length - 1)
        : baseUri.path;
    return baseUri.replace(
      path: '$basePath/$cleanPath',
      queryParameters: query,
    );
  }

  Map<String, Object?> _responseJson(http.Response response) {
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, Object?>) {
      throw FormatException(
        'Expected App Store Connect JSON object response.',
        response.body,
      );
    }
    return decoded;
  }

  List<Map<String, Object?>> _dataList(Map<String, Object?> response) {
    final data = response['data'];
    if (data is! List) {
      throw FormatException('Expected App Store Connect data list.', response);
    }
    return [
      for (final item in data)
        if (item is Map<String, Object?>) item,
    ];
  }

  Map<String, Object?> _dataObject(Map<String, Object?> response) {
    final data = response['data'];
    if (data is! Map<String, Object?>) {
      throw FormatException(
        'Expected App Store Connect data object.',
        response,
      );
    }
    return data;
  }

  String _resourceId(Map<String, Object?> resource, String label) {
    final id = resource['id'];
    if (id is! String || id.isEmpty) {
      throw FormatException('Missing App Store Connect $label id.', resource);
    }
    return id;
  }

  String _errorMessage(String body) {
    if (body.trim().isEmpty) {
      return 'empty response body';
    }
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, Object?>) {
        final errors = decoded['errors'];
        if (errors is List && errors.isNotEmpty) {
          return errors
              .whereType<Map<String, Object?>>()
              .map((error) {
                final title = error['title'];
                final detail = error['detail'];
                if (title is String && detail is String) {
                  return '$title: $detail';
                }
                return detail ?? title;
              })
              .whereType<String>()
              .join('; ');
        }
      }
    } on FormatException {
      return body;
    }
    return body;
  }
}

final class AppStoreBuild {
  final String id;
  final String? version;
  final String processingState;
  final String? buildAudienceType;

  const AppStoreBuild({
    required this.id,
    required this.version,
    required this.processingState,
    required this.buildAudienceType,
  });

  factory AppStoreBuild.fromJson(Map<String, Object?> resource) {
    final attributes = _attributes(resource);
    return AppStoreBuild(
      id: _id(resource, 'build'),
      version: attributes['version'] as String?,
      processingState: attributes['processingState'] as String? ?? 'UNKNOWN',
      buildAudienceType: attributes['buildAudienceType'] as String?,
    );
  }
}

final class AppStoreVersion {
  final String id;
  final String? versionString;
  final String? appVersionState;
  final String? appStoreState;

  const AppStoreVersion({
    required this.id,
    required this.versionString,
    required this.appVersionState,
    required this.appStoreState,
  });

  factory AppStoreVersion.fromJson(Map<String, Object?> resource) {
    final attributes = _attributes(resource);
    return AppStoreVersion(
      id: _id(resource, 'App Store version'),
      versionString: attributes['versionString'] as String?,
      appVersionState: attributes['appVersionState'] as String?,
      appStoreState: attributes['appStoreState'] as String?,
    );
  }

  bool get isEditableDraft =>
      appVersionState == 'PREPARE_FOR_SUBMISSION' ||
      appStoreState == 'PREPARE_FOR_SUBMISSION';
}

final class AppStoreVersionLocalization {
  final String id;
  final String? locale;

  const AppStoreVersionLocalization({required this.id, required this.locale});

  factory AppStoreVersionLocalization.fromJson(Map<String, Object?> resource) {
    final attributes = _attributes(resource);
    return AppStoreVersionLocalization(
      id: _id(resource, 'App Store version localization'),
      locale: attributes['locale'] as String?,
    );
  }
}

final class AppStoreDraftUpdateResult {
  final String appId;
  final String buildId;
  final String appStoreVersionId;
  final Map<String, String> localizationIdsByLocale;

  const AppStoreDraftUpdateResult({
    required this.appId,
    required this.buildId,
    required this.appStoreVersionId,
    this.localizationIdsByLocale = const {},
  });

  String? get localizationId {
    if (localizationIdsByLocale.length != 1) {
      return null;
    }
    return localizationIdsByLocale.values.single;
  }
}

Map<String, Object?> _attributes(Map<String, Object?> resource) {
  final attributes = resource['attributes'];
  if (attributes is Map<String, Object?>) {
    return attributes;
  }
  return const {};
}

String _id(Map<String, Object?> resource, String label) {
  final id = resource['id'];
  if (id is! String || id.isEmpty) {
    throw FormatException('Missing App Store Connect $label id.', resource);
  }
  return id;
}
