#!/usr/bin/env dart

import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:publisher_dart/publisher_dart.dart';

const _defaultTeamId = 'TUPCVWUMEF';
const _defaultTagPrefix = 'internal/ios/v';
const _defaultLocale = 'en-US';
const _defaultProcessingTimeoutSeconds = 1800;
const _defaultPollIntervalSeconds = 30;

const _usageHeader = '''
Publishes an Inkpad iOS build to TestFlight internal testing.

Run from inkpad-app/inkpad_app:
  dart ../../publisher-dart/tool/publish_internal_ios.dart [options]

Required App Store Connect auth options may also be provided with:
  APP_STORE_CONNECT_KEY_ID
  APP_STORE_CONNECT_ISSUER_ID
  APP_STORE_CONNECT_PRIVATE_KEY_PATH
  APP_STORE_CONNECT_APP_ID
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
  } on TimeoutException catch (error) {
    stderr.writeln(error.message);
    exitCode = 1;
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
    ..addOption('api-key-id', help: 'App Store Connect API key ID.')
    ..addOption('api-issuer-id', help: 'App Store Connect issuer ID.')
    ..addOption(
      'api-private-key',
      help: 'Path to the App Store Connect .p8 private key.',
    )
    ..addOption(
      'app-store-app-id',
      help: 'Numeric App Store Connect app ID, required for release notes.',
    )
    ..addOption(
      'upload-tool',
      defaultsTo: 'transporter',
      allowed: ['transporter', 'altool'],
      help: 'Tool used to upload the IPA.',
    )
    ..addOption(
      'transporter-verbosity',
      defaultsTo: 'informational',
      help: 'Transporter verbosity passed to -v.',
    )
    ..addOption('ipa', help: 'Use an existing IPA when --skip-build is passed.')
    ..addOption(
      'bump',
      defaultsTo: 'build',
      allowed: ['build', 'patch', 'minor', 'major'],
    )
    ..addOption(
      'whats-new',
      aliases: ['release-notes'],
      help: 'TestFlight what\'s-new text.',
    )
    ..addOption(
      'notes-file',
      aliases: ['release-notes-file'],
      help: 'File containing TestFlight what\'s-new text.',
    )
    ..addOption(
      'locale',
      defaultsTo: _defaultLocale,
      help: 'Beta build localization locale.',
    )
    ..addOption(
      'processing-timeout-seconds',
      defaultsTo: '$_defaultProcessingTimeoutSeconds',
      help: 'How long to wait for App Store Connect build processing.',
    )
    ..addOption(
      'poll-interval-seconds',
      defaultsTo: '$_defaultPollIntervalSeconds',
      help: 'How often to poll App Store Connect build processing.',
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
    ..addFlag('skip-testflight-notes', negatable: false)
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
    final whatsNew = releaseNotes?.forTestFlight();
    final credentials = _credentials(args, dryRun: dryRun);
    final publisher = IosInternalPublisher(
      context: context,
      runner: runner,
      credentials: credentials,
      teamId: args.option('team-id')!,
      uploadTool: IosUploadTool.parse(args.option('upload-tool')!),
      transporterVerbosity: args.option('transporter-verbosity')!,
    );

    final ipaFile = args.flag('skip-build')
        ? _resolveExistingIpa(args, context, dryRun: dryRun)
        : await publisher.buildIpa(version: nextVersion);

    if (!args.flag('skip-upload')) {
      if (dryRun) {
        stdout.writeln(
          'Would upload ${ipaFile.path} using ${args.option('upload-tool')}.',
        );
      } else {
        await publisher.uploadIpa(ipaFile: ipaFile);
        stdout.writeln('Uploaded iOS IPA ${ipaFile.path}.');
      }

      if (!args.flag('skip-crashlytics-symbols') && !args.flag('skip-build')) {
        await publisher.uploadCrashlyticsSymbols();
      }

      if (whatsNew != null && !args.flag('skip-testflight-notes')) {
        await _publishTestFlightNotes(
          args,
          credentials,
          version: nextVersion,
          whatsNew: whatsNew,
          dryRun: dryRun,
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
      stdout.writeln('Skipped upload; skipped git commit/tag.');
    }
  }

  String get _usage => '$_usageHeader\n${_parser.usage}';

  AppStoreConnectCredentials _credentials(
    ArgResults args, {
    required bool dryRun,
  }) {
    final keyId = _optionOrEnv(args, 'api-key-id', 'APP_STORE_CONNECT_KEY_ID');
    final issuerId = _optionOrEnv(
      args,
      'api-issuer-id',
      'APP_STORE_CONNECT_ISSUER_ID',
    );
    final privateKeyPath = _optionOrEnv(
      args,
      'api-private-key',
      'APP_STORE_CONNECT_PRIVATE_KEY_PATH',
    );
    final privateKeyFile = File(privateKeyPath);

    if (!dryRun && !privateKeyFile.existsSync()) {
      throw FileSystemException(
        'Missing App Store Connect private key.',
        privateKeyFile.path,
      );
    }

    return AppStoreConnectCredentials(
      keyId: keyId,
      issuerId: issuerId,
      privateKeyFile: privateKeyFile,
    );
  }

  Future<void> _publishTestFlightNotes(
    ArgResults args,
    AppStoreConnectCredentials credentials, {
    required AppVersion version,
    required String whatsNew,
    required bool dryRun,
  }) async {
    final appId = _optionOrEnv(
      args,
      'app-store-app-id',
      'APP_STORE_CONNECT_APP_ID',
    );
    final timeout = Duration(
      seconds: _positiveInt(args.option('processing-timeout-seconds')!),
    );
    final pollInterval = Duration(
      seconds: _positiveInt(args.option('poll-interval-seconds')!),
    );

    if (dryRun) {
      stdout.writeln(
        'Would wait for TestFlight build processing and set '
        '${args.option('locale')} release notes for app $appId.',
      );
      return;
    }

    final client = AppStoreConnectClient(credentials: credentials);
    try {
      final buildId = await client.waitForProcessedBuildId(
        appId: appId,
        version: version,
        timeout: timeout,
        pollInterval: pollInterval,
        log: stdout.writeln,
      );
      await client.upsertBetaBuildLocalization(
        buildId: buildId,
        locale: args.option('locale')!,
        whatsNew: whatsNew,
      );
      stdout.writeln('Updated TestFlight release notes for build $buildId.');
    } finally {
      client.close();
    }
  }

  File _resolveExistingIpa(
    ArgResults args,
    PublishContext context, {
    required bool dryRun,
  }) {
    final ipaPath = args.option('ipa');
    final ipaFile = File(ipaPath ?? context.defaultIosIpaFile.path);
    if (!dryRun && !ipaFile.existsSync()) {
      throw FileSystemException(
        'Missing IPA file. Pass --ipa or run without --skip-build.',
        ipaFile.path,
      );
    }
    return ipaFile;
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

  String _optionOrEnv(ArgResults args, String option, String envName) {
    final value = args.option(option)?.trim();
    if (value != null && value.isNotEmpty) {
      return value;
    }
    final envValue = Platform.environment[envName]?.trim();
    if (envValue != null && envValue.isNotEmpty) {
      return envValue;
    }
    throw _UsageError('Missing --$option or $envName.', _usage);
  }

  int _positiveInt(String value) {
    final parsed = int.tryParse(value);
    if (parsed == null || parsed <= 0) {
      throw FormatException('Expected a positive integer.', value);
    }
    return parsed;
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
