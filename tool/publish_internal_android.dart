#!/usr/bin/env dart

import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:publisher_dart/publisher_dart.dart';

const _defaultAndroidPackageName = 'com.workpail.inkpad.notepad.notes';
const _defaultTagPrefix = 'internal/android/v';

const _usageHeader = '''
Publishes an Inkpad Android build to Google Play internal testing.

Run from inkpad-app/inkpad_app:
  dart ../../publisher-dart/tool/publish_internal_android.dart [options]
''';

Future<void> main(List<String> args) async {
  try {
    await _AndroidCommand().run(args);
  } on _UsageError catch (error) {
    stderr.writeln(error.message);
    stderr.writeln('');
    stderr.writeln(error.usage);
    exitCode = 64;
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    if (error.source != null) {
      stderr.writeln(error.source);
    }
    exitCode = 64;
  } on FileSystemException catch (error) {
    stderr.writeln(error.message);
    if (error.path != null) {
      stderr.writeln(error.path);
    }
    exitCode = 2;
  } on ProcessException catch (error) {
    stderr.writeln(error);
    exitCode = error.errorCode == 0 ? 1 : error.errorCode;
  } on StateError catch (error) {
    stderr.writeln(error.message);
    exitCode = 1;
  }
}

final class _AndroidCommand {
  late final ArgParser _parser = ArgParser()
    ..addOption('app-dir', defaultsTo: Directory.current.path)
    ..addOption(
      'package-name',
      defaultsTo: _defaultAndroidPackageName,
      help: 'Google Play package name.',
    )
    ..addOption(
      'service-account',
      help: 'Path to the Google Play service-account JSON.',
    )
    ..addOption('track', defaultsTo: 'internal')
    ..addOption(
      'bump',
      defaultsTo: 'build',
      allowed: ['build', 'patch', 'minor', 'major'],
    )
    ..addOption(
      'whats-new',
      aliases: ['release-notes'],
      help: 'Release notes / what\'s-new text.',
    )
    ..addOption(
      'notes-file',
      aliases: ['release-notes-file'],
      help: 'File containing release notes / what\'s-new text.',
    )
    ..addOption(
      'tag-prefix',
      defaultsTo: _defaultTagPrefix,
      help: 'Git tag prefix. The bumped version is appended.',
    )
    ..addFlag(
      'stdin-release-notes',
      negatable: false,
      help: 'Read release notes from stdin.',
    )
    ..addFlag('allow-dirty', negatable: false)
    ..addFlag('skip-build', negatable: false)
    ..addFlag('skip-upload', negatable: false)
    ..addFlag('skip-git', negatable: false)
    ..addFlag(
      'push',
      negatable: false,
      help: 'Push commit and tag after tagging.',
    )
    ..addFlag('dry-run', negatable: false)
    ..addFlag('help', abbr: 'h', negatable: false);

  Future<void> run(List<String> rawArgs) async {
    final args = _parser.parse(rawArgs);
    if (args.flag('help')) {
      stdout.writeln(_usage);
      return;
    }

    final dryRun = args.flag('dry-run');
    final runner = ProcessRunner(dryRun: dryRun);
    final context = PublishContext(
      appDirectory: Directory(args.option('app-dir')!),
    );
    final git = GitClient(
      repositoryDirectory: context.parentDirectory.path,
      runner: runner,
    );

    final skipGit = args.flag('skip-git');
    if (!skipGit) {
      await git.requireClean(allowDirty: args.flag('allow-dirty'));
    }

    final versionFile = VersionFile(context.pubspecFile);
    final bump = VersionBump.parse(args.option('bump')!);
    final currentVersion = versionFile.read();
    final nextVersion = _nextVersion(currentVersion, bump);

    if (dryRun) {
      stdout.writeln('Would bump $currentVersion -> $nextVersion.');
    } else {
      versionFile.write(nextVersion);
      stdout.writeln('Bumped $currentVersion -> $nextVersion.');
    }

    final releaseNotes = await _resolveReleaseNotes(args);

    if (!args.flag('skip-build')) {
      await runner.run('flutter', const [
        'clean',
      ], workingDirectory: context.appDirectory.path);
      await runner.run('flutter', const [
        'build',
        'appbundle',
        '--release',
      ], workingDirectory: context.appDirectory.path);
    }

    if (!args.flag('skip-upload')) {
      final serviceAccountPath =
          args.option('service-account') ??
          context.androidServiceAccountFile.path;
      if (dryRun) {
        releaseNotes?.forGooglePlay();
        stdout.writeln(
          'Would upload ${context.androidReleaseBundle.path} to '
          '${args.option('track')} using $serviceAccountPath.',
        );
      } else {
        final versionCode = await AndroidInternalPublisher(
          serviceAccountFile: File(serviceAccountPath),
          appBundleFile: context.androidReleaseBundle,
          packageName: args.option('package-name')!,
          trackName: args.option('track')!,
        ).publish(version: nextVersion, releaseNotes: releaseNotes);
        stdout.writeln('Uploaded Android version code $versionCode.');
      }

      if (!skipGit) {
        final tagName = '${args.option('tag-prefix')}$nextVersion';
        await git.commitVersion(
          pubspecPath: p.relative(
            context.pubspecFile.path,
            from: context.parentDirectory.path,
          ),
          version: nextVersion.toString(),
        );
        await git.tag(
          tagName: tagName,
          version: nextVersion.toString(),
          platform: 'Android',
        );
        if (args.flag('push')) {
          await git.push(tagName: tagName);
        }
      }
    } else {
      stdout.writeln('Skipped upload; skipped git commit/tag.');
    }
  }

  String get _usage => '$_usageHeader\n${_parser.usage}';

  Future<ReleaseNotes?> _resolveReleaseNotes(ArgResults args) async {
    final sources = [
      if (args.option('whats-new') != null) '--whats-new',
      if (args.option('notes-file') != null) '--notes-file',
      if (args.flag('stdin-release-notes')) '--stdin-release-notes',
    ];
    if (sources.length > 1) {
      throw _UsageError(
        'Use only one release-notes source: ${sources.join(', ')}.',
        _usage,
      );
    }

    if (args.flag('stdin-release-notes')) {
      return ReleaseNotes.fromStdin();
    }
    return ReleaseNotes.fromValue(args.option('whats-new')) ??
        await ReleaseNotes.fromFile(args.option('notes-file'));
  }

  AppVersion _nextVersion(AppVersion current, VersionBump bump) {
    return switch (bump) {
      VersionBump.build => current.bumpBuild(),
      VersionBump.patch => current.bumpPatch(),
      VersionBump.minor => current.bumpMinor(),
      VersionBump.major => current.bumpMajor(),
    };
  }
}

final class _UsageError {
  final String message;
  final String usage;

  const _UsageError(this.message, this.usage);
}
