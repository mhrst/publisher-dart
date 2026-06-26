#!/usr/bin/env dart

import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:publisher_dart/publisher_dart.dart';

const _defaultTeamId = 'TUPCVWUMEF';
const _defaultTagPrefix = 'internal/ios/v';

const _usageHeader = '''
Publishes an Inkpad iOS build to App Store Connect.

Run from inkpad-app/inkpad_app:
  dart ../../publisher-dart/tool/publish_internal_ios.dart [options]

Authentication uses the Apple Developer account already installed in Xcode.
The account must have signing and App Store Connect upload access for Inkpad.
The uploaded build remains eligible for App Store distribution, but the script
does not submit it for review.
''';

Future<void> main(List<String> args) async {
  try {
    await _IosCommand().run(args);
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

final class _IosCommand {
  late final ArgParser _parser = ArgParser()
    ..addOption('app-dir', defaultsTo: Directory.current.path)
    ..addOption(
      'team-id',
      defaultsTo: _defaultTeamId,
      help: 'Apple Developer team ID.',
    )
    ..addOption(
      'archive',
      help: 'Existing .xcarchive directory to use with --skip-build.',
    )
    ..addOption(
      'bump',
      defaultsTo: 'build',
      allowed: ['build', 'patch', 'minor', 'major'],
    )
    ..addOption(
      'whats-new',
      aliases: ['release-notes'],
      help: 'App Store what\'s-new text to save with the upload.',
    )
    ..addOption(
      'notes-file',
      aliases: ['release-notes-file'],
      help: 'File containing App Store what\'s-new text.',
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
    ..addFlag(
      'skip-app-store-notes',
      aliases: ['skip-testflight-notes'],
      negatable: false,
      help: 'Skip saving App Store what\'s-new text.',
    )
    ..addFlag('skip-crashlytics-symbols', negatable: false)
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
    final archiveDirectory = _archiveDirectory(args, context);
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
    final whatsNew = releaseNotes?.forAppStoreVersion();
    final publisher = IosInternalPublisher(
      context: context,
      runner: runner,
      teamId: args.option('team-id')!,
      archiveDirectory: archiveDirectory,
    );

    if (!args.flag('skip-build')) {
      await publisher.buildArchive(version: nextVersion);
    } else if (!dryRun && !archiveDirectory.existsSync()) {
      throw FileSystemException(
        'Missing iOS archive directory. Pass --archive or run without --skip-build.',
        archiveDirectory.path,
      );
    }

    if (!args.flag('skip-upload')) {
      if (dryRun) {
        stdout.writeln(
          'Would upload ${archiveDirectory.path} using the local Xcode account.',
        );
      } else {
        await publisher.uploadArchive();
        stdout.writeln('Uploaded iOS archive ${archiveDirectory.path}.');
      }

      if (!args.flag('skip-crashlytics-symbols') && !args.flag('skip-build')) {
        await publisher.uploadCrashlyticsSymbols();
      }

      if (whatsNew != null && !args.flag('skip-app-store-notes')) {
        final notesFile = await publisher.writeAppStoreDraftNotes(whatsNew);
        final action = dryRun ? 'Would save' : 'Saved';
        stdout.writeln(
          '$action App Store draft release notes to ${notesFile.path}. Local '
          'Apple authentication uploads the build but does not update App '
          'Store Connect draft metadata automatically.',
        );
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
          platform: 'iOS',
        );
        if (args.flag('push')) {
          await git.push(tagName: tagName);
        }
      }
    } else {
      final ipaFile = await publisher.exportIpa();
      stdout.writeln('Skipped upload; exported iOS IPA ${ipaFile.path}.');
      stdout.writeln('Skipped git commit/tag.');
    }
  }

  String get _usage => '$_usageHeader\n${_parser.usage}';

  Directory _archiveDirectory(ArgResults args, PublishContext context) {
    final archivePath = args.option('archive')?.trim();
    if (archivePath != null && archivePath.isNotEmpty) {
      return Directory(archivePath).absolute;
    }
    return context.iosArchiveDirectory;
  }

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
