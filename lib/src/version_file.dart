import 'dart:io';

import 'package:publisher_dart/src/app_version.dart';
import 'package:yaml/yaml.dart';

final class VersionFile {
  final File file;

  VersionFile(this.file);

  AppVersion read() {
    if (!file.existsSync()) {
      throw FileSystemException('Missing pubspec.yaml.', file.path);
    }

    final content = file.readAsStringSync();
    final document = loadYaml(content);
    if (document is! YamlMap) {
      throw FormatException('Expected pubspec.yaml to contain a YAML map.');
    }

    final rawVersion = document['version'];
    if (rawVersion is! String) {
      throw FormatException(
        'Expected pubspec.yaml to contain a version string.',
      );
    }

    return AppVersion.parse(rawVersion);
  }
}
