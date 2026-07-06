import 'dart:io';

import 'package:googleapis/androidpublisher/v3.dart';
import 'package:googleapis_auth/auth_io.dart' show AutoRefreshingAuthClient;
import 'package:http/http.dart' as http;
import 'package:oauth_dart/oauth_dart.dart' as oauth;
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
  final File privateAuthFile;
  final void Function(String line) log;

  const AndroidUserOAuthCredentials({
    required this.privateAuthFile,
    this.log = print,
  });

  Future<AutoRefreshingAuthClient> createClient({
    required List<String> scopes,
  }) async {
    _requireFile(privateAuthFile, 'Google OAuth private auth JSON');

    return oauth.GoogleOAuthPrivateAuthClientFactory(
      privateAuthFile: privateAuthFile,
      tokenLabel: 'Google OAuth private auth file',
      consentDescription: 'Google Play publishing',
      onMessage: log,
    ).createClient(scopes: scopes);
  }

  void _requireFile(File file, String label) {
    if (!file.existsSync()) {
      throw FileSystemException('Missing $label.', file.path);
    }
  }
}
