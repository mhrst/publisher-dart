import 'package:publisher_dart/src/process_runner.dart';

final class GitClient {
  final String repositoryDirectory;
  final ProcessRunner runner;

  const GitClient({required this.repositoryDirectory, required this.runner});

  Future<bool> isClean() async {
    final result = await runner.run(
      'git',
      const ['status', '--porcelain'],
      workingDirectory: repositoryDirectory,
      streamOutput: false,
    );
    return result.stdoutText.trim().isEmpty;
  }

  Future<void> requireClean({required bool allowDirty}) async {
    if (allowDirty) {
      return;
    }
    if (!await isClean()) {
      throw StateError(
        'Git worktree is not clean. Commit/stash changes or pass --allow-dirty.',
      );
    }
  }

  Future<void> commitVersion({
    required String pubspecPath,
    required String version,
  }) async {
    await runner.run('git', [
      'add',
      pubspecPath,
    ], workingDirectory: repositoryDirectory);
    await runner.run('git', [
      'commit',
      '-m',
      'Bump internal build to $version',
    ], workingDirectory: repositoryDirectory);
  }

  Future<void> tag({
    required String tagName,
    required String version,
    required String platform,
  }) async {
    await runner.run('git', [
      'tag',
      '-a',
      tagName,
      '-m',
      'Internal $platform build $version',
    ], workingDirectory: repositoryDirectory);
  }

  Future<void> push({required String tagName}) async {
    await runner.run('git', const [
      'push',
    ], workingDirectory: repositoryDirectory);
    await runner.run('git', [
      'push',
      'origin',
      tagName,
    ], workingDirectory: repositoryDirectory);
  }
}
