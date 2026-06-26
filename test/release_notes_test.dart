import 'package:publisher_dart/publisher_dart.dart';
import 'package:test/test.dart';

void main() {
  test('treats empty text as absent notes', () {
    expect(ReleaseNotes.fromValue('   '), isNull);
  });

  test('trims only trailing whitespace', () {
    final notes = ReleaseNotes.fromValue('  New build\n\n');

    expect(notes?.value, '  New build');
  });

  test('rejects Google Play notes over the limit', () {
    final notes = ReleaseNotes.fromValue('x' * 501)!;

    expect(() => notes.forGooglePlay(), throwsFormatException);
  });
}
