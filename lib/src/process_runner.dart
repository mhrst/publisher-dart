import 'dart:async';
import 'dart:convert';
import 'dart:io';

final class ProcessRunner {
  final bool dryRun;
  final void Function(String line) log;

  const ProcessRunner({this.dryRun = false, this.log = print});

  Future<ProcessResultText> run(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    List<String>? displayArguments,
    Map<String, String>? environment,
    bool streamOutput = true,
    bool allowFailure = false,
  }) async {
    final commandText = _formatCommand(
      executable,
      displayArguments ?? arguments,
    );
    log('\$ $commandText');

    if (dryRun) {
      return const ProcessResultText(
        exitCode: 0,
        stdoutText: '',
        stderrText: '',
      );
    }

    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    );

    final stdoutBuffer = StringBuffer();
    final stderrBuffer = StringBuffer();

    final subscriptions = <StreamSubscription<void>>[
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            stdoutBuffer.writeln(line);
            if (streamOutput) {
              stdout.writeln(line);
            }
          }),
      process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            stderrBuffer.writeln(line);
            if (streamOutput) {
              stderr.writeln(line);
            }
          }),
    ];

    final exitCode = await process.exitCode;
    await Future.wait([
      for (final subscription in subscriptions) subscription.cancel(),
    ]);

    if (exitCode != 0 && !allowFailure) {
      throw ProcessException(
        executable,
        arguments,
        'Command failed with exit code $exitCode.',
        exitCode,
      );
    }

    return ProcessResultText(
      exitCode: exitCode,
      stdoutText: stdoutBuffer.toString(),
      stderrText: stderrBuffer.toString(),
    );
  }

  String _formatCommand(String executable, List<String> arguments) {
    return [executable, ...arguments].map(_shellQuote).join(' ');
  }

  String _shellQuote(String value) {
    if (RegExp(r'^[A-Za-z0-9_./:=@+-]+$').hasMatch(value)) {
      return value;
    }
    return "'${value.replaceAll("'", "'\\''")}'";
  }
}

final class ProcessResultText {
  final int exitCode;
  final String stdoutText;
  final String stderrText;

  const ProcessResultText({
    required this.exitCode,
    required this.stdoutText,
    required this.stderrText,
  });

  bool get succeeded => exitCode == 0;
}
