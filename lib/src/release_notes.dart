import 'dart:convert';
import 'dart:io';

final class ReleaseNotes {
  final String value;

  const ReleaseNotes._(this.value);

  static ReleaseNotes? fromValue(String? value) {
    final trimmed = value?.trimRight();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    return ReleaseNotes._(trimmed);
  }

  static Future<ReleaseNotes?> fromFile(String? path) async {
    if (path == null) {
      return null;
    }
    return fromValue(await File(path).readAsString());
  }

  static Future<ReleaseNotes?> fromStdin() async {
    final content = await stdin.transform(utf8.decoder).join();
    return fromValue(content);
  }

  String forGooglePlay({int maxLength = 500}) {
    if (value.length <= maxLength) {
      return value;
    }
    throw FormatException(
      'Google Play release notes must be $maxLength characters or fewer.',
      value,
    );
  }

  String forTestFlight({int maxLength = 4000}) {
    if (value.length <= maxLength) {
      return value;
    }
    throw FormatException(
      'TestFlight what\'s-new text must be $maxLength characters or fewer.',
      value,
    );
  }
}
