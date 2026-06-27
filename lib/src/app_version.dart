final class AppVersion implements Comparable<AppVersion> {
  final int major;
  final int minor;
  final int patch;
  final int buildNumber;

  const AppVersion({
    required this.major,
    required this.minor,
    required this.patch,
    required this.buildNumber,
  });

  factory AppVersion.parse(String value) {
    final match = RegExp(
      r'^(\d+)\.(\d+)\.(\d+)\+(\d+)$',
    ).firstMatch(value.trim());
    if (match == null) {
      throw FormatException(
        'Expected a Flutter version in the form x.y.z+build.',
        value,
      );
    }

    return AppVersion(
      major: int.parse(match.group(1)!),
      minor: int.parse(match.group(2)!),
      patch: int.parse(match.group(3)!),
      buildNumber: int.parse(match.group(4)!),
    );
  }

  @override
  int compareTo(AppVersion other) {
    final segments = [
      major.compareTo(other.major),
      minor.compareTo(other.minor),
      patch.compareTo(other.patch),
      buildNumber.compareTo(other.buildNumber),
    ];

    return segments.firstWhere((segment) => segment != 0, orElse: () => 0);
  }

  @override
  String toString() => '$major.$minor.$patch+$buildNumber';

  String get buildName => '$major.$minor.$patch';
}
