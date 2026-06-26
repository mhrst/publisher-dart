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

  AppVersion bump(VersionBump bump) {
    final current = read();
    final next = switch (bump) {
      VersionBump.build => current.bumpBuild(),
      VersionBump.patch => current.bumpPatch(),
      VersionBump.minor => current.bumpMinor(),
      VersionBump.major => current.bumpMajor(),
    };
    write(next);
    return next;
  }

  void write(AppVersion version) {
    final content = file.readAsStringSync();
    final lines = content.split('\n');
    final versionLinePattern = RegExp(r'^\s*version:\s*.+$');
    var changed = false;

    final updatedLines = [
      for (final line in lines)
        if (!changed && versionLinePattern.hasMatch(line))
          () {
            changed = true;
            final indent = RegExp(r'^(\s*)').firstMatch(line)!.group(1)!;
            return '${indent}version: $version';
          }()
        else
          line,
    ];

    if (!changed) {
      throw FormatException('Could not find a top-level version line.');
    }

    file.writeAsStringSync(updatedLines.join('\n'));
  }
}

enum VersionBump {
  build,
  patch,
  minor,
  major;

  static VersionBump parse(String value) {
    return switch (value) {
      'build' => VersionBump.build,
      'patch' => VersionBump.patch,
      'minor' => VersionBump.minor,
      'major' => VersionBump.major,
      _ => throw FormatException(
        'Expected one of: build, patch, minor, major.',
        value,
      ),
    };
  }
}
