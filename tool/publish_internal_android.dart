#!/usr/bin/env dart

import 'dart:io';

import 'package:args/args.dart';
import 'package:publisher_dart/publisher_dart.dart';

const _defaultAndroidPackageName = 'com.workpail.inkpad.notepad.notes';

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
    ..addOption('oauth-client', help: 'Path to the Google OAuth client JSON.')
    ..addOption(
      'oauth-token',
      help: 'Path to the cached Google OAuth token JSON.',
    )
    ..addOption(
      'oauth-port',
      defaultsTo: '0',
      help: 'Localhost callback port for first-time OAuth consent.',
    )
    ..addOption('track', defaultsTo: 'internal')
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
    ..addFlag(
      'stdin-release-notes',
      negatable: false,
      help: 'Read release notes from stdin.',
    )
    ..addFlag(
      'force-oauth-consent',
      negatable: false,
      help: 'Ignore the cached token and run the browser consent flow.',
    )
    ..addFlag('skip-build', negatable: false)
    ..addFlag('skip-upload', negatable: false)
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
      final oauthClientPath = _optionOrEnv(
        args,
        'oauth-client',
        'GOOGLE_PLAY_OAUTH_CLIENT',
        context.androidOAuthClientFile.path,
      );
      final oauthTokenPath = _optionOrEnv(
        args,
        'oauth-token',
        'GOOGLE_PLAY_OAUTH_TOKEN',
        context.androidOAuthTokenFile.path,
      );
      if (dryRun) {
        releaseNotes?.forGooglePlay();
        stdout.writeln(
          'Would upload ${context.androidReleaseBundle.path} to '
          '${args.option('track')} using OAuth client $oauthClientPath '
          'and token cache $oauthTokenPath.',
        );
      } else {
        final versionCode = await AndroidInternalPublisher(
          oauthCredentials: AndroidUserOAuthCredentials(
            clientSecretsFile: File(oauthClientPath),
            tokenStoreFile: File(oauthTokenPath),
            listenPort: _nonNegativeInt(args.option('oauth-port')!),
            forceConsent: args.flag('force-oauth-consent'),
          ),
          appBundleFile: context.androidReleaseBundle,
          packageName: args.option('package-name')!,
          trackName: args.option('track')!,
        ).publish(version: version, releaseNotes: releaseNotes);
        stdout.writeln('Uploaded Android version code $versionCode.');
      }
    } else {
      stdout.writeln('Skipped upload.');
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

  String _optionOrEnv(
    ArgResults args,
    String option,
    String envName,
    String defaultValue,
  ) {
    final value = args.option(option)?.trim();
    if (value != null && value.isNotEmpty) {
      return value;
    }
    final envValue = Platform.environment[envName]?.trim();
    if (envValue != null && envValue.isNotEmpty) {
      return envValue;
    }
    return defaultValue;
  }

  int _nonNegativeInt(String value) {
    final parsed = int.tryParse(value);
    if (parsed == null || parsed < 0) {
      throw FormatException('Expected a non-negative integer.', value);
    }
    return parsed;
  }
}

final class _UsageError {
  final String message;
  final String usage;

  const _UsageError(this.message, this.usage);
}
