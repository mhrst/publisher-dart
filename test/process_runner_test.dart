import 'package:publisher_dart/publisher_dart.dart';
import 'package:test/test.dart';

void main() {
  test(
    'logs display arguments instead of sensitive execution arguments',
    () async {
      final lines = <String>[];
      final runner = ProcessRunner(dryRun: true, log: lines.add);

      await runner.run(
        'xcrun',
        const ['iTMSTransporter', '-jwt', 'real-token'],
        displayArguments: const ['iTMSTransporter', '-jwt', '<redacted>'],
        workingDirectory: '.',
      );

      expect(lines, [r"$ xcrun iTMSTransporter -jwt '<redacted>'"]);
    },
  );
}
