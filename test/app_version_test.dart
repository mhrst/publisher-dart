import 'package:publisher_dart/publisher_dart.dart';
import 'package:test/test.dart';

void main() {
  test('parses Flutter version with build number', () {
    final version = AppVersion.parse('6.5.0+6501');

    expect(version.major, 6);
    expect(version.minor, 5);
    expect(version.patch, 0);
    expect(version.buildNumber, 6501);
    expect(version.buildName, '6.5.0');
  });

  test('bumps build without changing build name', () {
    final version = AppVersion.parse('6.5.0+6501').bumpBuild();

    expect(version.toString(), '6.5.0+6502');
  });

  test('bumps patch and build number together', () {
    final version = AppVersion.parse('6.5.0+6501').bumpPatch();

    expect(version.toString(), '6.5.1+6502');
  });
}
