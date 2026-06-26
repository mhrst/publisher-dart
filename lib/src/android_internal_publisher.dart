import 'dart:io';

import 'package:googleapis/androidpublisher/v3.dart';
import 'package:googleapis_auth/auth_io.dart';
import 'package:publisher_dart/src/app_version.dart';
import 'package:publisher_dart/src/release_notes.dart';

final class AndroidInternalPublisher {
  final File serviceAccountFile;
  final File appBundleFile;
  final String packageName;
  final String trackName;
  final void Function(String line) log;

  const AndroidInternalPublisher({
    required this.serviceAccountFile,
    required this.appBundleFile,
    required this.packageName,
    this.trackName = 'internal',
    this.log = print,
  });

  Future<int> publish({
    required AppVersion version,
    ReleaseNotes? releaseNotes,
  }) async {
    _requireFile(serviceAccountFile, 'Google Play service-account JSON');
    _requireFile(appBundleFile, 'Android app bundle');

    final credentials = ServiceAccountCredentials.fromJson(
      serviceAccountFile.readAsStringSync(),
    );
    final client = await clientViaServiceAccount(credentials, const [
      AndroidPublisherApi.androidpublisherScope,
    ]);

    try {
      final api = AndroidPublisherApi(client);
      log('Opening Google Play edit for $packageName.');
      final edit = await api.edits.insert(AppEdit(), packageName);
      final editId = edit.id;
      if (editId == null || editId.isEmpty) {
        throw StateError('Google Play did not return an edit id.');
      }

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

      final notes = releaseNotes?.forGooglePlay();
      if (notes != null) {
        release.releaseNotes = [
          LocalizedText()
            ..language = 'en-US'
            ..text = notes,
        ];
      }

      await api.edits.tracks.update(
        Track()
          ..track = trackName
          ..releases = [release],
        packageName,
        editId,
        trackName,
      );

      log('Committing Google Play edit $editId.');
      await api.edits.commit(packageName, editId);
      return versionCode;
    } finally {
      client.close();
    }
  }

  void _requireFile(File file, String label) {
    if (!file.existsSync()) {
      throw FileSystemException('Missing $label.', file.path);
    }
  }
}
