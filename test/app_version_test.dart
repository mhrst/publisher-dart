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

  test('formats Flutter version', () {
    final version = AppVersion.parse('6.5.0+6501');

    expect(version.toString(), '6.5.0+6501');
  });

  test('compares build numbers after build name segments', () {
    final older = AppVersion.parse('6.5.0+6501');
    final newer = AppVersion.parse('6.5.0+6502');

    expect(older.compareTo(newer), isNegative);
  });
}
