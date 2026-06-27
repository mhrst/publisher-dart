#!/usr/bin/env dart

import 'dart:io';

import 'package:args/args.dart';
import 'package:publisher_dart/publisher_dart.dart';

const _defaultTeamId = 'TUPCVWUMEF';
const _defaultBundleId = 'com.workpail.InkPad';
const _defaultMetadataLocale = 'en-US';
const _defaultBuildPollTimeoutSeconds = '1800';
const _defaultBuildPollIntervalSeconds = '30';

const _usageHeader = '''
Publishes an Inkpad iOS build to App Store Connect.

Run from inkpad-app/inkpad_app:
  dart ../../publisher-dart/tool/publish_internal_ios.dart [options]

Authentication uses the Apple Developer account already installed in Xcode.
The account must have signing and App Store Connect upload access for Inkpad.
The uploaded build remains eligible for App Store distribution, but the script
does not submit it for review.

Draft metadata uses an App Store Connect individual API key stored locally.
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
      'bundle-id',
      help:
          'App Store Connect bundle ID used to discover the app. Defaults to '
          'com.workpail.InkPad or APP_STORE_BUNDLE_ID.',
    )
    ..addOption(
      'app-store-app-id',
      help:
          'App Store Connect app resource ID. Defaults to lookup by '
          '--bundle-id or APP_STORE_APP_ID.',
    )
    ..addOption(
      'app-store-key-id',
      help: 'App Store Connect API key ID or APP_STORE_CONNECT_KEY_ID.',
    )
    ..addOption(
      'app-store-private-key',
      help:
          'Path to the App Store Connect API .p8 key. Defaults to '
          '../_secrets/app-store-connect-api-key.p8 or '
          'APP_STORE_CONNECT_PRIVATE_KEY.',
    )
    ..addOption(
      'app-store-issuer-id',
      help:
          'Optional issuer ID for a team API key. Omit for an individual API '
          'key, or set APP_STORE_CONNECT_ISSUER_ID.',
    )
    ..addOption(
      'metadata-locale',
      help:
          'App Store version localization to update. Defaults to en-US or '
          'APP_STORE_CONNECT_LOCALE.',
    )
    ..addOption(
      'build-poll-timeout',
      defaultsTo: _defaultBuildPollTimeoutSeconds,
      help: 'Seconds to wait for App Store Connect build processing.',
    )
    ..addOption(
      'build-poll-interval',
      defaultsTo: _defaultBuildPollIntervalSeconds,
      help: 'Seconds between App Store Connect build processing checks.',
    )
    ..addOption(
      'archive',
      help: 'Existing .xcarchive directory to use with --skip-build.',
    )
    ..addOption(
      'whats-new',
      aliases: ['release-notes'],
      help: 'App Store what\'s-new text for the draft metadata update.',
    )
    ..addOption(
      'notes-file',
      aliases: ['release-notes-file'],
      help: 'File containing App Store what\'s-new text.',
    )
    ..addFlag(
      'stdin-release-notes',
      negatable: false,
      help: 'Read release notes from stdin.',
    )
    ..addFlag('skip-build', negatable: false)
    ..addFlag('skip-upload', negatable: false)
    ..addFlag(
      'skip-app-store-metadata',
      negatable: false,
      help: 'Skip App Store Connect draft build linking and metadata update.',
    )
    ..addFlag(
      'skip-app-store-notes',
      aliases: ['skip-testflight-notes'],
      negatable: false,
      help: 'Skip updating App Store what\'s-new text.',
    )
    ..addFlag('skip-crashlytics-symbols', negatable: false)
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

    final version = VersionFile(context.pubspecFile).read();
    stdout.writeln('Using app version $version.');

    final releaseNotes = await _resolveReleaseNotes(args);
    final whatsNew = releaseNotes?.forAppStoreVersion();
    final publisher = IosInternalPublisher(
      context: context,
      runner: runner,
      teamId: args.option('team-id')!,
      archiveDirectory: archiveDirectory,
    );

    if (!args.flag('skip-build')) {
      await publisher.buildArchive(version: version);
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

      if (!args.flag('skip-app-store-metadata')) {
        await _updateAppStoreDraft(
          args: args,
          context: context,
          version: version,
          whatsNew: args.flag('skip-app-store-notes') ? null : whatsNew,
          dryRun: dryRun,
        );
      }
    } else {
      final ipaFile = await publisher.exportIpa();
      stdout.writeln('Skipped upload; exported iOS IPA ${ipaFile.path}.');
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

  Future<void> _updateAppStoreDraft({
    required ArgResults args,
    required PublishContext context,
    required AppVersion version,
    required String? whatsNew,
    required bool dryRun,
  }) async {
    final appId = _optionOrEnv(args, 'app-store-app-id', 'APP_STORE_APP_ID');
    final bundleId =
        _optionOrEnv(args, 'bundle-id', 'APP_STORE_BUNDLE_ID') ??
        _defaultBundleId;
    final locale =
        _optionOrEnv(args, 'metadata-locale', 'APP_STORE_CONNECT_LOCALE') ??
        _defaultMetadataLocale;
    final buildPollTimeout = _durationOption(args, 'build-poll-timeout');
    final buildPollInterval = _durationOption(args, 'build-poll-interval');

    if (dryRun) {
      stdout.writeln(
        'Would update App Store Connect draft metadata for '
        '${appId == null ? 'bundle ID $bundleId' : 'app $appId'}.',
      );
      stdout.writeln(
        'Would wait up to ${buildPollTimeout.inSeconds}s for build '
        '${version.buildNumber} (${version.buildName}) to process.',
      );
      stdout.writeln(
        'Would attach the processed build to App Store version '
        '${version.buildName}.',
      );
      if (whatsNew != null) {
        stdout.writeln('Would update $locale App Store what\'s-new metadata.');
      }
      return;
    }

    final client = AppStoreConnectClient(
      tokenProvider: _appStoreConnectCredentials(args, context),
    );
    try {
      final result = await client.updateDraftSubmission(
        appId: appId,
        bundleId: bundleId,
        version: version,
        whatsNew: whatsNew,
        locale: locale,
        buildPollTimeout: buildPollTimeout,
        buildPollInterval: buildPollInterval,
      );
      stdout.writeln(
        'Updated App Store draft ${result.appStoreVersionId} with build '
        '${result.buildId}.',
      );
      if (result.localizationId != null) {
        stdout.writeln(
          'Updated $locale App Store what\'s-new metadata '
          '(${result.localizationId}).',
        );
      }
    } finally {
      client.close();
    }
  }

  AppStoreConnectCredentials _appStoreConnectCredentials(
    ArgResults args,
    PublishContext context,
  ) {
    return AppStoreConnectCredentials(
      keyId: _requiredOptionOrEnv(
        args,
        'app-store-key-id',
        'APP_STORE_CONNECT_KEY_ID',
      ),
      privateKeyFile: _appStorePrivateKeyFile(args, context),
      issuerId: _optionOrEnv(
        args,
        'app-store-issuer-id',
        'APP_STORE_CONNECT_ISSUER_ID',
      ),
    );
  }

  File _appStorePrivateKeyFile(ArgResults args, PublishContext context) {
    final path = _optionOrEnv(
      args,
      'app-store-private-key',
      'APP_STORE_CONNECT_PRIVATE_KEY',
    );
    if (path == null) {
      return context.iosAppStoreConnectPrivateKeyFile;
    }
    return File(path).absolute;
  }

  Duration _durationOption(ArgResults args, String option) {
    final value = args.option(option)!;
    final seconds = int.tryParse(value);
    if (seconds == null || seconds <= 0) {
      throw _UsageError(
        '--$option must be a positive integer number of seconds.',
        _usage,
      );
    }
    return Duration(seconds: seconds);
  }

  String _requiredOptionOrEnv(
    ArgResults args,
    String option,
    String environmentKey,
  ) {
    final value = _optionOrEnv(args, option, environmentKey);
    if (value == null) {
      throw _UsageError('Missing --$option or $environmentKey.', _usage);
    }
    return value;
  }

  String? _optionOrEnv(ArgResults args, String option, String environmentKey) {
    final optionValue = args.option(option)?.trim();
    if (optionValue != null && optionValue.isNotEmpty) {
      return optionValue;
    }
    final environmentValue = Platform.environment[environmentKey]?.trim();
    if (environmentValue != null && environmentValue.isNotEmpty) {
      return environmentValue;
    }
    return null;
  }
}

final class _UsageError {
  final String message;
  final String usage;

  const _UsageError(this.message, this.usage);
}
