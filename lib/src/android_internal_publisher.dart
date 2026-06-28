import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:googleapis/androidpublisher/v3.dart';
import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;
import 'package:publisher_dart/src/app_version.dart';
import 'package:publisher_dart/src/release_notes.dart';

final class AndroidInternalPublisher {
  final AndroidUserOAuthCredentials oauthCredentials;
  final File appBundleFile;
  final String packageName;
  final String trackName;
  final String defaultReleaseNotesLocale;
  final void Function(String line) log;
  final Future<http.Client> Function({required List<String> scopes})
  _createClient;

  AndroidInternalPublisher({
    required this.oauthCredentials,
    required this.appBundleFile,
    required this.packageName,
    this.trackName = 'internal',
    this.defaultReleaseNotesLocale = ReleaseNotes.defaultGooglePlayLanguage,
    this.log = print,
    Future<http.Client> Function({required List<String> scopes})? createClient,
  }) : _createClient = createClient ?? oauthCredentials.createClient;

  Future<int> publish({
    required AppVersion version,
    ReleaseNotes? releaseNotes,
  }) async {
    _requireFile(appBundleFile, 'Android app bundle');

    final client = await _createGooglePlayClient();

    try {
      final api = AndroidPublisherApi(client);
      final editId = await _openEdit(api);

      log('Uploading ${appBundleFile.path}.');
      final bundle = await api.edits.bundles.upload(
        packageName,
        editId,
        uploadMedia: Media(
          appBundleFile.openRead(),
          appBundleFile.lengthSync(),
          contentType: 'application/octet-stream',
        ),
      );
      final versionCode = bundle.versionCode;
      if (versionCode == null) {
        throw StateError('Google Play did not return a bundle version code.');
      }

      log('Assigning version code $versionCode to $trackName.');
      final release = TrackRelease()
        ..name = version.toString()
        ..status = 'completed'
        ..versionCodes = ['$versionCode'];

      final notes = releaseNotes?.forGooglePlay(
        defaultLanguage: defaultReleaseNotesLocale,
      );
      if (notes != null && notes.isNotEmpty) {
        release.releaseNotes = _localizedReleaseNotes(notes);
      }

      await api.edits.tracks.update(
        Track()
          ..track = trackName
          ..releases = [release],
        packageName,
        editId,
        trackName,
      );

      await _commitEdit(api, editId);
      return versionCode;
    } finally {
      client.close();
    }
  }

  Future<int> updateReleaseNotes({
    required AppVersion version,
    required ReleaseNotes releaseNotes,
  }) async {
    final versionCode = version.buildNumber.toString();
    final notes = releaseNotes.forGooglePlay(
      defaultLanguage: defaultReleaseNotesLocale,
    );
    final client = await _createGooglePlayClient();

    try {
      final api = AndroidPublisherApi(client);
      final editId = await _openEdit(api);

      log('Loading Google Play $trackName track.');
      final track = await api.edits.tracks.get(packageName, editId, trackName);
      final release = _releaseForVersionCode(track, versionCode);
      release.releaseNotes = _localizedReleaseNotes(notes);

      log(
        'Updating release notes for version code $versionCode on $trackName.',
      );
      await api.edits.tracks.update(track, packageName, editId, trackName);
      await _commitEdit(api, editId);
      return version.buildNumber;
    } finally {
      client.close();
    }
  }

  Future<http.Client> _createGooglePlayClient() {
    return _createClient(
      scopes: const [AndroidPublisherApi.androidpublisherScope],
    );
  }

  Future<String> _openEdit(AndroidPublisherApi api) async {
    log('Opening Google Play edit for $packageName.');
    final edit = await api.edits.insert(AppEdit(), packageName);
    final editId = edit.id;
    if (editId == null || editId.isEmpty) {
      throw StateError('Google Play did not return an edit id.');
    }
    return editId;
  }

  Future<void> _commitEdit(AndroidPublisherApi api, String editId) async {
    log('Committing Google Play edit $editId.');
    await api.edits.commit(packageName, editId);
  }

  TrackRelease _releaseForVersionCode(Track track, String versionCode) {
    final releases = track.releases;
    if (releases == null || releases.isEmpty) {
      throw StateError('Google Play $trackName track has no releases.');
    }

    for (final release in releases) {
      if (release.versionCodes?.contains(versionCode) ?? false) {
        return release;
      }
    }

    throw StateError(
      'Google Play $trackName track has no release for version code '
      '$versionCode. Confirm pubspec.yaml build number matches the uploaded '
      'Android version code.',
    );
  }

  List<LocalizedText> _localizedReleaseNotes(Map<String, String> notes) {
    final entries = notes.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return [
      for (final entry in entries)
        LocalizedText()
          ..language = entry.key
          ..text = entry.value,
    ];
  }

  void _requireFile(File file, String label) {
    if (!file.existsSync()) {
      throw FileSystemException('Missing $label.', file.path);
    }
  }
}

final class AndroidUserOAuthCredentials {
  final File clientSecretsFile;
  final File tokenStoreFile;
  final int listenPort;
  final bool forceConsent;
  final void Function(String line) log;

  const AndroidUserOAuthCredentials({
    required this.clientSecretsFile,
    required this.tokenStoreFile,
    this.listenPort = 0,
    this.forceConsent = false,
    this.log = print,
  });

  Future<AutoRefreshingAuthClient> createClient({
    required List<String> scopes,
  }) async {
    _requireFile(clientSecretsFile, 'Google OAuth client JSON');

    final clientId = GoogleOAuthClientId.fromJson(
      _readJsonObject(clientSecretsFile),
    ).toClientId();
    final baseClient = http.Client();

    try {
      final credentials = await _credentials(
        clientId: clientId,
        scopes: scopes,
        baseClient: baseClient,
      );
      final client = autoRefreshingClient(clientId, credentials, baseClient);
      client.credentialUpdates.listen(_writeCredentials);
      return client;
    } catch (_) {
      baseClient.close();
      rethrow;
    }
  }

  Future<AccessCredentials> _credentials({
    required ClientId clientId,
    required List<String> scopes,
    required http.Client baseClient,
  }) async {
    if (!forceConsent && tokenStoreFile.existsSync()) {
      final credentials = AccessCredentials.fromJson(
        _readJsonObject(tokenStoreFile),
      );
      if (credentials.refreshToken != null &&
          _coversScopes(credentials.scopes, scopes)) {
        log('Using cached Google OAuth token ${tokenStoreFile.path}.');
        return credentials;
      }
      log(
        'Cached Google OAuth token is missing a refresh token or does not '
        'cover the requested scopes; '
        'requesting consent again.',
      );
    }

    log('Requesting Google OAuth consent for Google Play publishing.');
    final credentials = await _obtainOfflineAccessCredentials(
      clientId,
      scopes,
      baseClient,
    );
    if (credentials.refreshToken == null) {
      throw StateError(
        'Google OAuth did not return a refresh token. Revoke the existing '
        'grant for this OAuth client and rerun with --force-oauth-consent.',
      );
    }
    _writeCredentials(credentials);
    return credentials;
  }

  Future<AccessCredentials> _obtainOfflineAccessCredentials(
    ClientId clientId,
    List<String> scopes,
    http.Client baseClient,
  ) async {
    final server = await HttpServer.bind('localhost', listenPort);

    try {
      final redirectUri = 'http://localhost:${server.port}';
      final state = _randomState();
      final codeVerifier = _createCodeVerifier();
      final authorizationUri = _authorizationUri(
        clientId: clientId,
        scopes: scopes,
        redirectUri: redirectUri,
        state: state,
        codeVerifier: codeVerifier,
      );

      _promptUserForConsent(authorizationUri.toString());

      final request = await server.first;
      try {
        if (request.method != 'GET') {
          throw StateError('Invalid OAuth callback method: ${request.method}.');
        }
        if (request.uri.queryParameters['state'] != state) {
          throw StateError('Invalid OAuth callback state.');
        }
        final error = request.uri.queryParameters['error'];
        if (error != null) {
          throw StateError('Google OAuth failed: $error.');
        }
        final code = request.uri.queryParameters['code'];
        if (code == null || code.isEmpty) {
          throw StateError('Google OAuth callback did not include a code.');
        }

        final credentials = await obtainAccessCredentialsViaCodeExchange(
          baseClient,
          clientId,
          code,
          redirectUrl: redirectUri,
          codeVerifier: codeVerifier,
        );

        request.response
          ..statusCode = 200
          ..headers.set('content-type', 'text/html; charset=UTF-8')
          ..write('''
<!DOCTYPE html>
<html>
  <head><meta charset="utf-8"><title>Authorization successful</title></head>
  <body><h2>Authorization successful. You can close this window.</h2></body>
</html>
''');
        await request.response.close();
        return credentials;
      } catch (_) {
        request.response.statusCode = 500;
        await request.response.close().catchError((_) {});
        rethrow;
      }
    } finally {
      await server.close();
    }
  }

  void _promptUserForConsent(String uri) {
    log('Authorize Google Play publishing in your browser:');
    log(uri);

    if (Platform.isMacOS) {
      unawaited(() async {
        try {
          await Process.start('open', [uri], mode: ProcessStartMode.detached);
        } on ProcessException catch (error) {
          log('Could not open the browser automatically: ${error.message}');
        }
      }());
    }
  }

  void _writeCredentials(AccessCredentials credentials) {
    tokenStoreFile.parent.createSync(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    tokenStoreFile.writeAsStringSync(
      '${encoder.convert(credentials.toJson())}\n',
    );
    log('Saved Google OAuth token ${tokenStoreFile.path}.');
  }

  bool _coversScopes(List<String> actualScopes, List<String> requiredScopes) {
    final actual = actualScopes.toSet();
    return requiredScopes.every(actual.contains);
  }

  Uri _authorizationUri({
    required ClientId clientId,
    required List<String> scopes,
    required String redirectUri,
    required String state,
    required String codeVerifier,
  }) {
    return Uri.https('accounts.google.com', 'o/oauth2/v2/auth', {
      'client_id': clientId.identifier,
      'response_type': 'code',
      'redirect_uri': redirectUri,
      'scope': scopes.join(' '),
      'code_challenge': _codeChallenge(codeVerifier),
      'code_challenge_method': 'S256',
      'access_type': 'offline',
      'prompt': 'consent',
      'state': state,
    });
  }

  String _createCodeVerifier() {
    const safe =
        '0123456789-._~'
        'abcdefghijklmnopqrstuvwxyz'
        'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
    final random = Random.secure();
    return List.generate(128, (_) => safe[random.nextInt(safe.length)]).join();
  }

  String _codeChallenge(String codeVerifier) {
    final digest = sha256.convert(ascii.encode(codeVerifier));
    return _stripBase64Padding(base64UrlEncode(digest.bytes));
  }

  String _randomState() {
    final random = Random.secure();
    final bytes = Uint8List.fromList([
      for (var i = 0; i < 24; i++) random.nextInt(256),
    ]);
    return _stripBase64Padding(base64UrlEncode(bytes));
  }

  String _stripBase64Padding(String value) {
    return value.replaceAll(RegExp(r'=+$'), '');
  }

  Map<String, dynamic> _readJsonObject(File file) {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    throw FormatException('Expected a JSON object.', decoded);
  }

  void _requireFile(File file, String label) {
    if (!file.existsSync()) {
      throw FileSystemException('Missing $label.', file.path);
    }
  }
}

final class GoogleOAuthClientId {
  final String identifier;
  final String? secret;

  const GoogleOAuthClientId({required this.identifier, this.secret});

  factory GoogleOAuthClientId.fromJson(Map<String, dynamic> json) {
    final googleConfig = json['installed'] ?? json['web'];
    if (googleConfig is Map<String, dynamic>) {
      return GoogleOAuthClientId(
        identifier: _requiredString(googleConfig, 'client_id'),
        secret: googleConfig['client_secret'] as String?,
      );
    }

    return GoogleOAuthClientId(
      identifier: _requiredString(json, 'identifier'),
      secret: json['secret'] as String?,
    );
  }

  ClientId toClientId() => ClientId(identifier, secret);

  static String _requiredString(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is String && value.isNotEmpty) {
      return value;
    }
    throw FormatException('Expected "$key" to be a non-empty string.', json);
  }
}
