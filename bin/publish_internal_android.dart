#!/usr/bin/env dart

import 'dart:io';

import 'package:args/args.dart';
import 'package:publisher_dart/publisher_dart.dart';

const _defaultReleaseNotesLocale = 'en-US';

const _usageHeader = '''
Publishes a Flutter Android build to Google Play internal testing.

Run from a Flutter app directory:
  dart run publisher_dart:publish_internal_android [options]
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
  } on AndroidPublisherAuthorizationRequiredException catch (error) {
    stderr.writeln(error.message);
    exitCode = 1;
  } on StateError catch (error) {
    stderr.writeln(error.message);
    exitCode = 1;
  }
}

final class _AndroidCommand {
  late final ArgParser _parser = ArgParser()
    ..addOption('app-dir', defaultsTo: Directory.current.path)
    ..addOption('package-name', help: 'Google Play package name.')
    ..addOption(
      'oauth-token',
      help: 'Path to the Google OAuth token JSON or GOOGLE_OAUTH_TOKEN.',
    )
    ..addOption('track', defaultsTo: 'internal')
    ..addOption('release-notes', help: 'Google Play release notes text.')
    ..addOption(
      'release-notes-file',
      help:
          'Plain text file or localized .yaml/.yml file containing release '
          'notes.',
    )
    ..addOption(
      'release-notes-locale',
      help:
          'Google Play language for plain-text release notes or the YAML '
          'default fallback. Defaults to en-US.',
    )
    ..addFlag(
      'release-notes-stdin',
      negatable: false,
      help: 'Read release notes from stdin.',
    )
    ..addFlag('skip-build', negatable: false)
    ..addFlag('skip-upload', negatable: false)
    ..addFlag(
      'only-release-notes',
      negatable: false,
      help:
          'Only update Google Play release notes for the current pubspec.yaml '
          'build number.',
    )
    ..addFlag('dry-run', negatable: false)
    ..addFlag('help', abbr: 'h', negatable: false);

  Future<void> run(List<String> rawArgs) async {
    final args = _parser.parse(rawArgs);
    if (args.flag('help')) {
      stdout.writeln(_usage);
      return;
    }
    _validateMode(args);

    final dryRun = args.flag('dry-run');
    final runner = ProcessRunner(dryRun: dryRun);
    final context = PublishContext(
      appDirectory: Directory(args.option('app-dir')!),
    );

    final version = VersionFile(context.pubspecFile).read();
    stdout.writeln('Using app version $version.');

    final releaseNotes = await _resolveReleaseNotes(args);
    final releaseNotesLocale = _releaseNotesLocale(args);

    if (args.flag('only-release-notes')) {
      final requiredReleaseNotes = _requireReleaseNotes(releaseNotes);
      final packageName = _packageName(args);
      final oauthTokenPath = _requiredOptionOrEnv(
        args,
        'oauth-token',
        'GOOGLE_OAUTH_TOKEN',
      );
      if (dryRun) {
        requiredReleaseNotes.forGooglePlay(defaultLanguage: releaseNotesLocale);
        stdout.writeln(
          'Would update Google Play ${args.option('track')} release notes for '
          'version code ${version.buildNumber} using OAuth token file '
          '$oauthTokenPath.',
        );
      } else {
        final versionCode =
            await AndroidInternalPublisher(
              oauthCredentials: AndroidUserOAuthCredentials(
                oauthTokenFile: File(oauthTokenPath),
              ),
              appBundleFile: context.androidReleaseBundle,
              packageName: packageName,
              trackName: args.option('track')!,
              defaultReleaseNotesLocale: releaseNotesLocale,
            ).updateReleaseNotes(
              version: version,
              releaseNotes: requiredReleaseNotes,
            );
        stdout.writeln(
          'Updated Android release notes for version code $versionCode.',
        );
      }
      return;
    }

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
      final packageName = _packageName(args);
      final oauthTokenPath = _requiredOptionOrEnv(
        args,
        'oauth-token',
        'GOOGLE_OAUTH_TOKEN',
      );
      if (dryRun) {
        releaseNotes?.forGooglePlay(defaultLanguage: releaseNotesLocale);
        stdout.writeln(
          'Would upload ${context.androidReleaseBundle.path} to '
          '${args.option('track')} using OAuth token file $oauthTokenPath.',
        );
      } else {
        final versionCode = await AndroidInternalPublisher(
          oauthCredentials: AndroidUserOAuthCredentials(
            oauthTokenFile: File(oauthTokenPath),
          ),
          appBundleFile: context.androidReleaseBundle,
          packageName: packageName,
          trackName: args.option('track')!,
          defaultReleaseNotesLocale: releaseNotesLocale,
        ).publish(version: version, releaseNotes: releaseNotes);
        stdout.writeln('Uploaded Android version code $versionCode.');
      }
    } else {
      stdout.writeln('Skipped upload.');
    }
  }

  String get _usage => '$_usageHeader\n${_parser.usage}';

  void _validateMode(ArgResults args) {
    if (args.flag('only-release-notes') && args.flag('skip-upload')) {
      throw _UsageError(
        'Use either --only-release-notes or --skip-upload, not both.',
        _usage,
      );
    }
  }

  Future<ReleaseNotes?> _resolveReleaseNotes(ArgResults args) async {
    final sources = [
      if (args.option('release-notes') != null) '--release-notes',
      if (args.option('release-notes-file') != null) '--release-notes-file',
      if (args.flag('release-notes-stdin')) '--release-notes-stdin',
    ];
    if (sources.length > 1) {
      throw _UsageError(
        'Use only one release-notes source: ${sources.join(', ')}.',
        _usage,
      );
    }

    if (args.flag('release-notes-stdin')) {
      return ReleaseNotes.fromStdin();
    }
    return ReleaseNotes.fromValue(args.option('release-notes')) ??
        await ReleaseNotes.fromFile(args.option('release-notes-file'));
  }

  ReleaseNotes _requireReleaseNotes(ReleaseNotes? releaseNotes) {
    if (releaseNotes == null) {
      throw _UsageError(
        '--only-release-notes requires --release-notes, '
        '--release-notes-file, or --release-notes-stdin.',
        _usage,
      );
    }
    return releaseNotes;
  }

  String _packageName(ArgResults args) {
    return _requiredOption(args, 'package-name');
  }

  String _releaseNotesLocale(ArgResults args) {
    return _option(args, 'release-notes-locale') ?? _defaultReleaseNotesLocale;
  }

  String _requiredOption(ArgResults args, String option) {
    final value = _option(args, option);
    if (value != null) {
      return value;
    }
    throw _UsageError('Missing --$option.', _usage);
  }

  String? _option(ArgResults args, String option) {
    final value = args.option(option)?.trim();
    if (value != null && value.isNotEmpty) {
      return value;
    }
    return null;
  }

  String _requiredOptionOrEnv(ArgResults args, String option, String envName) {
    final value = _optionOrEnv(args, option, envName);
    if (value != null) {
      return value;
    }
    throw _UsageError('Missing --$option or $envName.', _usage);
  }

  String? _optionOrEnv(ArgResults args, String option, String envName) {
    final value = args.option(option)?.trim();
    if (value != null && value.isNotEmpty) {
      return value;
    }
    final envValue = Platform.environment[envName]?.trim();
    if (envValue != null && envValue.isNotEmpty) {
      return envValue;
    }
    return null;
  }
}

final class _UsageError {
  final String message;
  final String usage;

  const _UsageError(this.message, this.usage);
}
