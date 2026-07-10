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

  Directory get iosArchiveDirectory => Directory(
    p.join(appDirectory.path, 'build', 'ios', 'archive', 'Runner.xcarchive'),
  );

  Directory get iosIpaDirectory =>
      Directory(p.join(appDirectory.path, 'build', 'ios', 'ipa'));
}
