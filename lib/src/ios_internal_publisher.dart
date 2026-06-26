import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:publisher_dart/src/app_version.dart';
import 'package:publisher_dart/src/process_runner.dart';
import 'package:publisher_dart/src/publish_context.dart';

final class IosInternalPublisher {
  final PublishContext context;
  final ProcessRunner runner;
  final String teamId;
  final Directory archiveDirectory;

  IosInternalPublisher({
    required this.context,
    required this.runner,
    required this.teamId,
    Directory? archiveDirectory,
  }) : archiveDirectory =
           (archiveDirectory ?? context.iosArchiveDirectory).absolute;

  Future<void> buildArchive({required AppVersion version}) async {
    await _cleanFlutterNativeAssetOutputs();

    await runner.run('flutter', [
      'build',
      'ios',
      '--config-only',
      '--release',
      '--build-name',
      version.buildName,
      '--build-number',
      version.buildNumber.toString(),
    ], workingDirectory: context.appDirectory.path);

    await runner.run('xcodebuild', [
      '-workspace',
      'Runner.xcworkspace',
      '-scheme',
      'Runner',
      '-configuration',
      'Release',
      '-destination',
      'generic/platform=iOS',
      '-archivePath',
      archiveDirectory.path,
      '-allowProvisioningUpdates',
      'FLUTTER_BUILD_NAME=${version.buildName}',
      'FLUTTER_BUILD_NUMBER=${version.buildNumber}',
      'archive',
    ], workingDirectory: context.iosDirectory.path);

    await _verifyAppStoreNativeAssets();
  }

  Future<File> exportIpa() async {
    await runner.run('xcodebuild', [
      '-exportArchive',
      '-archivePath',
      archiveDirectory.path,
      '-exportPath',
      context.iosIpaDirectory.path,
      '-exportOptionsPlist',
      (await _writeExportOptionsPlist(
        destination: XcodeArchiveDestination.export,
      )).path,
    ], workingDirectory: context.iosDirectory.path);

    if (runner.dryRun) {
      return context.defaultIosIpaFile;
    }
    return _findIpaFile();
  }

  Future<void> uploadArchive() async {
    if (!runner.dryRun && !archiveDirectory.existsSync()) {
      throw FileSystemException(
        'Missing iOS archive directory.',
        archiveDirectory.path,
      );
    }

    await runner.run('xcodebuild', [
      '-exportArchive',
      '-archivePath',
      archiveDirectory.path,
      '-exportPath',
      context.iosIpaDirectory.path,
      '-exportOptionsPlist',
      (await _writeExportOptionsPlist(
        destination: XcodeArchiveDestination.upload,
      )).path,
    ], workingDirectory: context.iosDirectory.path);
  }

  Future<File> writeTestFlightNotes(String whatsNew) async {
    final directory = Directory(
      p.join(context.appDirectory.path, '.dart_tool', 'publisher_dart'),
    );
    final file = File(p.join(directory.path, 'testflight_whats_new.txt'));

    if (runner.dryRun) {
      runner.log('Would write ${file.path}');
      return file;
    }

    await directory.create(recursive: true);
    await file.writeAsString('$whatsNew\n');
    return file;
  }

  Future<void> uploadCrashlyticsSymbols() async {
    final dsymDirectory = Directory(p.join(archiveDirectory.path, 'dSYMs'));

    if (!runner.dryRun) {
      if (!context.iosCrashlyticsUploadSymbols.existsSync()) {
        throw FileSystemException(
          'Missing Firebase Crashlytics upload-symbols script.',
          context.iosCrashlyticsUploadSymbols.path,
        );
      }
      if (!context.iosGoogleServiceInfoFile.existsSync()) {
        throw FileSystemException(
          'Missing GoogleService-Info.plist.',
          context.iosGoogleServiceInfoFile.path,
        );
      }
      if (!dsymDirectory.existsSync()) {
        throw FileSystemException(
          'Missing archive dSYMs directory.',
          dsymDirectory.path,
        );
      }
    }

    await runner.run(
      context.iosCrashlyticsUploadSymbols.path,
      [
        '-gsp',
        context.iosGoogleServiceInfoFile.path,
        '-p',
        'ios',
        dsymDirectory.path,
      ],
      workingDirectory: context.appDirectory.path,
    );
  }

  Future<void> _cleanFlutterNativeAssetOutputs() async {
    await _deleteDirectory(
      Directory(
        p.join(context.appDirectory.path, 'build', 'native_assets', 'ios'),
      ),
    );

    final flutterBuildDirectory = Directory(
      p.join(context.appDirectory.path, '.dart_tool', 'flutter_build'),
    );
    if (!flutterBuildDirectory.existsSync()) {
      return;
    }

    const targetOutputs = {
      'dart_build.d',
      'dart_build.stamp',
      'dart_build_result.json',
      'native_assets.json',
      'install_code_assets.d',
      'install_code_assets.stamp',
    };

    for (final entity in flutterBuildDirectory.listSync()) {
      if (entity is! Directory) {
        continue;
      }
      for (final filename in targetOutputs) {
        await _deleteFile(File(p.join(entity.path, filename)));
      }
    }
  }

  Future<void> _deleteDirectory(Directory directory) async {
    if (runner.dryRun) {
      runner.log('Would delete ${directory.path}');
      return;
    }
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
  }

  Future<void> _deleteFile(File file) async {
    if (runner.dryRun) {
      runner.log('Would delete ${file.path}');
      return;
    }
    if (file.existsSync()) {
      await file.delete();
    }
  }

  Future<File> _writeExportOptionsPlist({
    required XcodeArchiveDestination destination,
  }) async {
    final directory = Directory(
      p.join(context.appDirectory.path, '.dart_tool', 'publisher_dart'),
    );
    final file = File(
      p.join(directory.path, 'ExportOptions-${destination.value}.plist'),
    );

    if (runner.dryRun) {
      runner.log('Would write ${file.path}');
      return file;
    }

    await directory.create(recursive: true);
    await file.writeAsString('''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>method</key>
\t<string>app-store-connect</string>
\t<key>signingStyle</key>
\t<string>automatic</string>
\t<key>teamID</key>
\t<string>$teamId</string>
\t<key>manageAppVersionAndBuildNumber</key>
\t<false/>
\t<key>uploadSymbols</key>
\t<true/>
\t<key>testFlightInternalTestingOnly</key>
\t<true/>
\t<key>destination</key>
\t<string>${destination.value}</string>
</dict>
</plist>
''');
    return file;
  }

  Future<void> _verifyAppStoreNativeAssets() async {
    if (runner.dryRun) {
      runner.log('Would verify app-store archive native assets.');
      return;
    }

    final applicationsDirectory = Directory(
      p.join(archiveDirectory.path, 'Products', 'Applications'),
    );
    if (!applicationsDirectory.existsSync()) {
      return;
    }

    final appDirectory = applicationsDirectory
        .listSync()
        .whereType<Directory>()
        .where((directory) => directory.path.endsWith('.app'))
        .firstOrNull;
    if (appDirectory == null) {
      return;
    }

    for (final frameworkName in const ['objective_c', 'sqlite3']) {
      final executable = File(
        p.join(
          appDirectory.path,
          'Frameworks',
          '$frameworkName.framework',
          frameworkName,
        ),
      );
      if (!executable.existsSync()) {
        continue;
      }

      final result = await runner.run(
        'xcrun',
        ['vtool', '-show-build', executable.path],
        workingDirectory: context.appDirectory.path,
        streamOutput: false,
        allowFailure: true,
      );
      if ('${result.stdoutText}\n${result.stderrText}'.contains(
        'platform IOSSIMULATOR',
      )) {
        throw StateError(
          '$frameworkName.framework was built for the iOS simulator and '
          'cannot be uploaded to App Store Connect. Delete '
          'build/native_assets/ios and rerun the publisher.',
        );
      }
    }
  }

  File _findIpaFile() {
    if (context.defaultIosIpaFile.existsSync()) {
      return context.defaultIosIpaFile;
    }
    if (!context.iosIpaDirectory.existsSync()) {
      throw FileSystemException(
        'Missing iOS IPA export directory.',
        context.iosIpaDirectory.path,
      );
    }

    final ipaFiles =
        context.iosIpaDirectory
            .listSync()
            .whereType<File>()
            .where((file) => p.extension(file.path) == '.ipa')
            .toList()
          ..sort((a, b) {
            return b.lastModifiedSync().compareTo(a.lastModifiedSync());
          });

    if (ipaFiles.isEmpty) {
      throw FileSystemException(
        'No IPA file found after xcodebuild export.',
        context.iosIpaDirectory.path,
      );
    }

    return ipaFiles.first;
  }
}

enum XcodeArchiveDestination {
  export('export'),
  upload('upload');

  final String value;

  const XcodeArchiveDestination(this.value);
}
