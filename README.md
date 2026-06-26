# publisher-dart

Dart scripts for publishing Inkpad internal Android and iOS builds.

The package is intended to replace the internal Fastlane lanes while keeping
the release flow explicit:

- bump the Flutter build number in `inkpad_app/pubspec.yaml`
- build the Android AAB or iOS IPA
- upload to Google Play internal testing or TestFlight
- optionally attach "what's new" / release notes
- commit the version bump and create a matching git tag

The scripts are designed to run from `inkpad-app/inkpad_app`.

```sh
dart ../../publisher-dart/tool/publish_internal_android.dart --whats-new "Internal test build"
dart ../../publisher-dart/tool/publish_internal_ios.dart --whats-new "Internal test build"
```

The app Makefile forwards `ARGS` to these scripts:

```sh
make deploy_internal_android ARGS='--whats-new "Internal test build"'
make deploy_internal_ios ARGS='--whats-new "Internal test build"'
```

## Android

Android uses the Google Play Developer API directly through `googleapis` and
`googleapis_auth`. Authentication uses an installed-app OAuth client and a
cached user refresh token, not a service-account JSON. Defaults match the old
internal lane where they still apply:

- package name: `com.workpail.inkpad.notepad.notes`
- track: `internal`
- OAuth client JSON: `../_secrets/google-play-oauth-client.json`
- cached OAuth token: `../_secrets/google-play-oauth-token.json`
- git tag prefix: `internal/android/v`

The first upload opens a browser consent flow and writes the token cache.
Later uploads refresh that token automatically. The signed-in Google account
must have Google Play Console access for the app.

OAuth paths can also be passed with options or env:

- `--oauth-client` or `GOOGLE_PLAY_OAUTH_CLIENT`
- `--oauth-token` or `GOOGLE_PLAY_OAUTH_TOKEN`

Useful options:

```sh
dart ../../publisher-dart/tool/publish_internal_android.dart \
  --whats-new "Internal test build" \
  --push
```

## iOS

iOS builds an App Store Connect archive and uploads it with `xcodebuild` using
the Apple Developer account already installed in Xcode. The account must have
signing and App Store Connect upload access for Inkpad.

The upload path intentionally does not require App Store Connect API keys,
Transporter JWTs, or app-specific passwords. First make sure Xcode can see the
right account under Xcode > Settings > Accounts.

When release notes are supplied, the script validates the TestFlight length and
saves them to `.dart_tool/publisher_dart/testflight_whats_new.txt`. Local Xcode
authentication does not expose an official metadata API for setting TestFlight
what's-new text automatically.

```sh
dart ../../publisher-dart/tool/publish_internal_ios.dart \
  --whats-new "Internal test build" \
  --push
```

## Safety switches

Both scripts support:

- `--dry-run`
- `--skip-build`
- `--skip-upload`
- `--skip-git`
- `--allow-dirty`
- `--bump build|patch|minor|major`
