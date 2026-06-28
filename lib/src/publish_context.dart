import 'dart:io';

import 'package:path/path.dart' as p;

final class PublishContext {
  final Directory appDirectory;

  PublishContext({required Directory appDirectory})
    : appDirectory = appDirectory.absolute;

  File get pubspecFile => File(p.join(appDirectory.path, 'pubspec.yaml'));
  Directory get androidDirectory =>
      Directory(p.join(appDirectory.path, 'android'));
  Directory get iosDirectory => Directory(p.join(appDirectory.path, 'ios'));

  File get androidReleaseBundle => File(
    p.join(
      appDirectory.path,
      'build',
      'app',
      'outputs',
      'bundle',
      'release',
      'app-release.aab',
    ),
  );

  File get iosFirebaseAppIdFile =>
      File(p.join(iosDirectory.path, 'firebase_app_id_file.json'));

  File get iosGoogleServiceInfoFile =>
      File(p.join(iosDirectory.path, 'Runner', 'GoogleService-Info.plist'));

  File get iosCrashlyticsUploadSymbols => File(
    p.join(iosDirectory.path, 'Pods', 'FirebaseCrashlytics', 'upload-symbols'),
  );

  Directory get iosArchiveDirectory => Directory(
    p.join(appDirectory.path, 'build', 'ios', 'archive', 'Runner.xcarchive'),
  );

  Directory get iosIpaDirectory =>
      Directory(p.join(appDirectory.path, 'build', 'ios', 'ipa'));
}
