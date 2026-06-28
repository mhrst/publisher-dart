import 'package:publisher_dart/publisher_dart.dart';
import 'package:test/test.dart';

void main() {
  test('treats empty text as absent notes', () {
    expect(ReleaseNotes.fromValue('   '), isNull);
  });

  test('trims only trailing whitespace', () {
    final notes = ReleaseNotes.fromValue('  New build\n\n');

    expect(notes?.value, '  New build');
    expect(notes?.forGooglePlay(), {'en-US': '  New build'});
  });

  test('rejects Google Play notes over the limit', () {
    final notes = ReleaseNotes.fromValue('x' * 501)!;

    expect(() => notes.forGooglePlay(), throwsFormatException);
  });

  test('rejects App Store notes over the limit', () {
    final notes = ReleaseNotes.fromValue('x' * 4001)!;

    expect(() => notes.forAppStoreVersion(), throwsFormatException);
  });

  test('parses localized YAML release notes', () {
    final notes = ReleaseNotes.fromYaml('''
default: |
  Shared fallback
es-419, es-MX: |
  Spanish notes
''')!;

    expect(notes.forGooglePlay(), {
      'en-US': 'Shared fallback',
      'es-419': 'Spanish notes',
    });
    expect(notes.forAppStoreVersion(), {
      'en-US': 'Shared fallback',
      'es-MX': 'Spanish notes',
    });
  });

  test('allows platform-specific locale code differences', () {
    final notes = ReleaseNotes.fromYaml('''
zh-CN, zh-Hans: |
  Simplified Chinese notes
''')!;

    expect(notes.forGooglePlay(), {'zh-CN': 'Simplified Chinese notes'});
    expect(notes.forAppStoreVersion(), {'zh-Hans': 'Simplified Chinese notes'});
  });

  test('rejects invalid Google Play language codes', () {
    expect(
      () => ReleaseNotes.fromYaml('''
en_US, en-US: Invalid
'''),
      throwsFormatException,
    );
  });

  test('rejects unsupported App Store locales', () {
    expect(
      () => ReleaseNotes.fromYaml('''
es-419: Invalid for App Store
'''),
      throwsFormatException,
    );
  });
}
