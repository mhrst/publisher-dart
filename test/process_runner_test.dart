import 'package:publisher_dart/publisher_dart.dart';
import 'package:test/test.dart';

void main() {
  test(
    'logs display arguments instead of sensitive execution arguments',
    () async {
      final lines = <String>[];
      final runner = ProcessRunner(dryRun: true, log: lines.add);

      await runner.run(
        'tool',
        const ['upload', '--token', 'real-token'],
        displayArguments: const ['upload', '--token', '<redacted>'],
        workingDirectory: '.',
      );

      expect(lines, [r"$ tool upload --token '<redacted>'"]);
    },
  );
}
