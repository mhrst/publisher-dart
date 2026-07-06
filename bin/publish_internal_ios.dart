#!/usr/bin/env dart

import 'dart:io';

import 'package:args/args.dart';
import 'package:publisher_dart/publisher_dart.dart';

const _defaultWhatsNewLocale = 'en-US';
const _defaultBuildPollTimeoutSeconds = '1800';
const _defaultBuildPollIntervalSeconds = '30';

const _usageHeader = '''
Publishes a Flutter iOS build to App Store Connect.

Run from a Flutter app directory:
  dart run publisher_dart:publish_internal_ios [options]

Authentication uses the Apple Developer account already installed in Xcode.
The account must have signing and App Store Connect upload access for the app.
The uploaded build remains eligible for App Store distribution, but the script
does not submit it for review.

What's-new metadata uses a local App Store Connect API key when what's-new text
is provided.
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
    ..addOption('team-id', help: 'Apple Developer team ID.')
    ..addOption(
      'bundle-id',
      help:
          'App Store Connect bundle ID. Required unless --app-store-app-id is '
          'set.',
    )
    ..addOption(
      'app-store-app-id',
      help:
          'App Store Connect app resource ID. If omitted, the app is looked '
          'up by bundle ID.',
    )
    ..addOption(
      'whats-new-locale',
      help:
          'App Store localization for plain-text what\'s-new text or the YAML '
          'default fallback. Defaults to en-US.',
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
    ..addOption('whats-new', help: 'App Store what\'s-new text.')
    ..addOption(
      'whats-new-file',
      help:
          'Plain text file or localized .yaml/.yml file containing App Store '
          'what\'s-new text.',
    )
    ..addFlag(
      'whats-new-stdin',
      negatable: false,
      help: 'Read App Store what\'s-new text from stdin.',
    )
    ..addFlag('skip-build', negatable: false)
    ..addFlag('skip-upload', negatable: false)
    ..addFlag(
      'only-whats-new',
      negatable: false,
      help:
          'Only update App Store what\'s-new text for the current '
          'pubspec.yaml version.',
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

    final version = VersionFile(context.pubspecFile).read();
    stdout.writeln('Using app version $version.');

    final releaseNotes = await _resolveReleaseNotes(args);

    if (args.flag('only-whats-new')) {
      final requiredWhatsNew = _requireWhatsNew(releaseNotes);
      await _updateAppStoreWhatsNew(
        args: args,
        version: version,
        releaseNotes: requiredWhatsNew,
        dryRun: dryRun,
      );
      return;
    }

    final archiveDirectory = _archiveDirectory(args, context);
    final publisher = IosInternalPublisher(
      context: context,
      runner: runner,
      teamId: _requiredOption(args, 'team-id'),
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

      await publisher.uploadCrashlyticsSymbols();

      if (releaseNotes != null) {
        await _updateAppStoreWhatsNewAfterUpload(
          args: args,
          version: version,
          releaseNotes: releaseNotes,
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
      if (args.option('whats-new-file') != null) '--whats-new-file',
      if (args.flag('whats-new-stdin')) '--whats-new-stdin',
    ];
    if (sources.length > 1) {
      throw _UsageError(
        'Use only one what\'s-new source: ${sources.join(', ')}.',
        _usage,
      );
    }

    if (args.flag('whats-new-stdin')) {
      return ReleaseNotes.fromStdin();
    }
    return ReleaseNotes.fromValue(args.option('whats-new')) ??
        await ReleaseNotes.fromFile(args.option('whats-new-file'));
  }

  ReleaseNotes _requireWhatsNew(ReleaseNotes? releaseNotes) {
    if (releaseNotes == null) {
      throw _UsageError(
        '--only-whats-new requires --whats-new, --whats-new-file, or '
        '--whats-new-stdin.',
        _usage,
      );
    }
    return releaseNotes;
  }

  Future<void> _updateAppStoreWhatsNew({
    required ArgResults args,
    required AppVersion version,
    required ReleaseNotes releaseNotes,
    required bool dryRun,
  }) async {
    final appId = _option(args, 'app-store-app-id');
    final bundleId = _bundleIdForLookup(args, appId);
    final locale = _option(args, 'whats-new-locale') ?? _defaultWhatsNewLocale;
    final whatsNewByLocale = releaseNotes.forAppStoreVersion(
      defaultLocale: locale,
    );

    if (dryRun) {
      stdout.writeln(
        'Would update App Store what\'s-new metadata for '
        '${_localeList(whatsNewByLocale.keys)} on version '
        '${version.buildName}.',
      );
      return;
    }

    final client = AppStoreConnectClient(
      tokenProvider: _appStoreConnectCredentials(args),
    );
    try {
      final resolvedAppId = await client.resolveAppId(
        appId: appId,
        bundleId: bundleId,
      );
      final appStoreVersion = await client.findOrCreateAppStoreVersion(
        appId: resolvedAppId,
        versionString: version.buildName,
        reuseExistingDraft: true,
      );
      final localizationIdsByLocale = <String, String>{};
      final entries = whatsNewByLocale.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      final skippedLocales = <String>[];
      for (final entry in entries) {
        final localization = await client.findLocalization(
          appStoreVersionId: appStoreVersion.id,
          locale: entry.key,
        );
        if (localization == null) {
          skippedLocales.add(entry.key);
          continue;
        }
        await client.updateWhatsNew(
          localizationId: localization.id,
          whatsNew: entry.value,
        );
        localizationIdsByLocale[entry.key] = localization.id;
      }
      if (localizationIdsByLocale.isEmpty && entries.isNotEmpty) {
        throw StateError(
          'App Store version ${appStoreVersion.id} has no localizations for '
          '${_localeList(entries.map((entry) => entry.key))}. Add those '
          'localizations in App Store Connect or remove them from the '
          'what\'s-new file.',
        );
      }
      for (final entry in localizationIdsByLocale.entries) {
        stdout.writeln(
          'Updated ${entry.key} App Store what\'s-new metadata '
          '(${entry.value}).',
        );
      }
      if (skippedLocales.isNotEmpty) {
        stdout.writeln(
          'Skipped App Store what\'s-new metadata for '
          '${_localeList(skippedLocales)} because the App Store version does '
          'not list those localizations.',
        );
      }
    } finally {
      client.close();
    }
  }

  Future<void> _updateAppStoreWhatsNewAfterUpload({
    required ArgResults args,
    required AppVersion version,
    required ReleaseNotes releaseNotes,
    required bool dryRun,
  }) async {
    final appId = _option(args, 'app-store-app-id');
    final bundleId = _bundleIdForLookup(args, appId);
    final locale = _option(args, 'whats-new-locale') ?? _defaultWhatsNewLocale;
    final whatsNewByLocale = releaseNotes.forAppStoreVersion(
      defaultLocale: locale,
    );
    final buildPollTimeout = _durationOption(args, 'build-poll-timeout');
    final buildPollInterval = _durationOption(args, 'build-poll-interval');

    if (dryRun) {
      stdout.writeln(
        'Would update App Store what\'s-new metadata for '
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
      if (whatsNewByLocale.isNotEmpty) {
        stdout.writeln(
          'Would update App Store what\'s-new metadata for '
          '${_localeList(whatsNewByLocale.keys)}.',
        );
      }
      return;
    }

    final client = AppStoreConnectClient(
      tokenProvider: _appStoreConnectCredentials(args),
    );
    try {
      final result = await client.updateDraftSubmission(
        appId: appId,
        bundleId: bundleId,
        version: version,
        whatsNewByLocale: whatsNewByLocale,
        buildPollTimeout: buildPollTimeout,
        buildPollInterval: buildPollInterval,
      );
      stdout.writeln(
        'Updated App Store draft ${result.appStoreVersionId} with build '
        '${result.buildId}.',
      );
      for (final entry in result.localizationIdsByLocale.entries) {
        stdout.writeln(
          'Updated ${entry.key} App Store what\'s-new metadata '
          '(${entry.value}).',
        );
      }
    } finally {
      client.close();
    }
  }

  AppStoreConnectCredentials _appStoreConnectCredentials(ArgResults args) {
    return AppStoreConnectCredentials(
      keyId: _requiredEnvironment('APP_STORE_CONNECT_KEY_ID'),
      privateKeyFile: _appStorePrivateKeyFile(),
      issuerId: _environment('APP_STORE_CONNECT_ISSUER_ID'),
    );
  }

  File _appStorePrivateKeyFile() {
    final path = _requiredEnvironment('APP_STORE_CONNECT_PRIVATE_KEY');
    return File(path).absolute;
  }

  String _bundleIdForLookup(ArgResults args, String? appId) {
    final bundleId = _option(args, 'bundle-id');
    if (bundleId != null) {
      return bundleId;
    }
    if (appId != null && appId.trim().isNotEmpty) {
      return '';
    }
    throw _UsageError('Missing --bundle-id or --app-store-app-id.', _usage);
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

  String _localeList(Iterable<String> locales) {
    final sorted = locales.toList()..sort();
    return sorted.join(', ');
  }

  String _requiredEnvironment(String environmentKey) {
    final value = _environment(environmentKey);
    if (value != null) {
      return value;
    }
    throw _UsageError('Missing $environmentKey.', _usage);
  }

  String? _environment(String environmentKey) {
    final value = Platform.environment[environmentKey]?.trim();
    if (value != null && value.isNotEmpty) {
      return value;
    }
    return null;
  }

  String _requiredOption(ArgResults args, String option) {
    final value = _option(args, option);
    if (value != null) {
      return value;
    }
    throw _UsageError('Missing --$option.', _usage);
  }

  String? _option(ArgResults args, String option) {
    final optionValue = args.option(option)?.trim();
    if (optionValue != null && optionValue.isNotEmpty) {
      return optionValue;
    }
    return null;
  }
}

final class _UsageError {
  final String message;
  final String usage;

  const _UsageError(this.message, this.usage);
}
