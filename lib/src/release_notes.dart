import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

final class ReleaseNotes {
  static const defaultGooglePlayLanguage = 'en-US';
  static const defaultAppStoreLocale = 'en-US';

  static const appStoreLocaleCodes = <String>{
    'ar-SA',
    'bn',
    'ca',
    'cs',
    'da',
    'de-DE',
    'el',
    'en-AU',
    'en-CA',
    'en-GB',
    'en-US',
    'es-ES',
    'es-MX',
    'fi',
    'fr-CA',
    'fr-FR',
    'gu',
    'he',
    'hi',
    'hr',
    'hu',
    'id',
    'it',
    'ja',
    'kn',
    'ko',
    'ml',
    'mr',
    'ms',
    'nl-NL',
    'no',
    'or',
    'pa',
    'pl',
    'pt-BR',
    'pt-PT',
    'ro',
    'ru',
    'sk',
    'sl',
    'sv',
    'ta',
    'te',
    'th',
    'tr',
    'uk',
    'ur',
    'vi',
    'zh-Hans',
    'zh-Hant',
  };

  static final RegExp _googlePlayLanguageCode = RegExp(
    r'^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$',
  );

  final String? value;
  final Map<String, String> android;
  final Map<String, String> ios;

  ReleaseNotes._({
    required this.value,
    Map<String, String> android = const {},
    Map<String, String> ios = const {},
  }) : android = Map.unmodifiable(android),
       ios = Map.unmodifiable(ios);

  static ReleaseNotes? fromValue(String? value) {
    final trimmed = value?.trimRight();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    return ReleaseNotes._(value: trimmed);
  }

  static Future<ReleaseNotes?> fromFile(String? path) async {
    if (path == null) {
      return null;
    }
    final content = await File(path).readAsString();
    if (_isYamlPath(path)) {
      return fromYaml(content);
    }
    return fromValue(content);
  }

  static Future<ReleaseNotes?> fromStdin() async {
    final content = await stdin.transform(utf8.decoder).join();
    return fromValue(content);
  }

  static ReleaseNotes? fromYaml(String content) {
    final document = loadYaml(content);
    if (document == null) {
      return null;
    }

    if (document is String) {
      return fromValue(document);
    }
    if (document is! YamlMap) {
      throw FormatException(
        'Release notes YAML must be a map of locale code keys to text.',
        content,
      );
    }

    String? defaultValue;
    final android = <String, String>{};
    final ios = <String, String>{};
    final aliasesByAndroidLocale = <String, String>{};
    final aliasesByIosLocale = <String, String>{};
    for (final entry in document.entries) {
      final key = entry.key;
      if (key is! String || key.trim().isEmpty) {
        throw FormatException(
          'Release notes YAML locale keys must be non-empty strings.',
          key,
        );
      }

      final alias = key.trim();
      if (alias == 'default') {
        defaultValue = _optionalText(entry.value, 'default');
        continue;
      }

      final codes = _parseLocaleKey(alias);
      final text = _requiredText(entry.value, alias);
      final previousAndroidAlias = aliasesByAndroidLocale[codes.android];
      if (previousAndroidAlias != null) {
        throw FormatException(
          'Release notes YAML contains duplicate Android locale entries '
          '"$previousAndroidAlias" and "$alias".',
          alias,
        );
      }
      final previousAlias = aliasesByIosLocale[codes.ios];
      if (previousAlias != null) {
        throw FormatException(
          'Release notes YAML contains duplicate iOS locale entries '
          '"$previousAlias" and "$alias".',
          alias,
        );
      }
      aliasesByAndroidLocale[codes.android] = alias;
      aliasesByIosLocale[codes.ios] = alias;
      android[codes.android] = text;
      ios[codes.ios] = text;
    }

    if (defaultValue == null && android.isEmpty && ios.isEmpty) {
      return null;
    }
    return ReleaseNotes._(value: defaultValue, android: android, ios: ios);
  }

  Map<String, String> forGooglePlay({
    int maxLength = 500,
    String defaultLanguage = defaultGooglePlayLanguage,
  }) {
    final notes = <String, String>{};
    if (value != null) {
      _validateGooglePlayLanguage(defaultLanguage);
      notes[defaultLanguage] = value!;
    }
    notes.addAll(android);
    for (final entry in notes.entries) {
      _validateLength(
        text: entry.value,
        maxLength: maxLength,
        label: 'Google Play release notes for ${entry.key}',
      );
    }
    return notes;
  }

  Map<String, String> forAppStoreVersion({
    int maxLength = 4000,
    String defaultLocale = defaultAppStoreLocale,
  }) {
    final notes = <String, String>{};
    if (value != null) {
      _validateAppStoreLocale(defaultLocale);
      notes[defaultLocale] = value!;
    }
    notes.addAll(ios);
    for (final entry in notes.entries) {
      _validateLength(
        text: entry.value,
        maxLength: maxLength,
        label: 'App Store what\'s-new text for ${entry.key}',
      );
    }
    return notes;
  }

  Map<String, String> forTestFlight({
    int maxLength = 4000,
    String defaultLocale = defaultAppStoreLocale,
  }) {
    return forAppStoreVersion(
      maxLength: maxLength,
      defaultLocale: defaultLocale,
    );
  }

  static bool _isYamlPath(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.yaml') || lower.endsWith('.yml');
  }

  static String? _optionalText(Object? value, String path) {
    if (value == null) {
      return null;
    }
    if (value is! String) {
      throw FormatException(
        'Release notes YAML value "$path" must be a string.',
        value,
      );
    }
    final trimmed = value.trimRight();
    if (trimmed.isEmpty) {
      return null;
    }
    return trimmed;
  }

  static String _requiredText(Object? value, String path) {
    final text = _optionalText(value, path);
    if (text == null) {
      throw FormatException(
        'Release notes YAML value "$path" must not be empty.',
        value,
      );
    }
    return text;
  }

  static _StoreLocaleCodes _parseLocaleKey(String key) {
    final parts = key
        .split(',')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.length != 1 && parts.length != 2) {
      throw FormatException(
        'Release notes YAML key "$key" must be either "locale" or '
        '"android-locale, ios-locale".',
        key,
      );
    }

    final android = parts.first;
    final ios = parts.length == 1 ? parts.first : parts.last;
    _validateGooglePlayLanguage(android);
    _validateAppStoreLocale(ios);
    return _StoreLocaleCodes(android: android, ios: ios);
  }

  static void _validateGooglePlayLanguage(String language) {
    if (!_googlePlayLanguageCode.hasMatch(language)) {
      throw FormatException(
        'Google Play release-note language "$language" must be a '
        'hyphenated BCP 47 code such as en-US, es-419, or pt-BR.',
        language,
      );
    }
  }

  static String _supportedAppStoreLocaleMessage() {
    return 'Supported App Store locales are: ${appStoreLocaleCodes.join(', ')}.';
  }

  static void _validateAppStoreLocale(String locale) {
    if (!appStoreLocaleCodes.contains(locale)) {
      throw FormatException(
        'Unsupported App Store locale "$locale". '
        '${_supportedAppStoreLocaleMessage()}',
        locale,
      );
    }
  }

  static void _validateLength({
    required String text,
    required int maxLength,
    required String label,
  }) {
    if (text.length > maxLength) {
      throw FormatException(
        '$label must be $maxLength characters or fewer.',
        text,
      );
    }
  }
}

final class _StoreLocaleCodes {
  final String android;
  final String ios;

  const _StoreLocaleCodes({required this.android, required this.ios});
}
