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
`googleapis_auth`. Defaults match the old internal lane:

- package name: `com.workpail.inkpad.notepad.notes`
- track: `internal`
- service-account JSON: `../_secrets/inkpadnotepad-39534ebaf0b6.json`
- git tag prefix: `internal/android/v`

Useful options:

```sh
dart ../../publisher-dart/tool/publish_internal_android.dart \
  --whats-new "Internal test build" \
  --push
```

## iOS

iOS builds an App Store Connect export, uploads the IPA with Transporter by
default, then optionally waits for TestFlight processing and writes the
what's-new text through the App Store Connect API.

Required App Store Connect authentication can be passed with options or env:

- `--api-key-id` or `APP_STORE_CONNECT_KEY_ID`
- `--api-issuer-id` or `APP_STORE_CONNECT_ISSUER_ID`
- `--api-private-key` or `APP_STORE_CONNECT_PRIVATE_KEY_PATH`
- `--app-store-app-id` or `APP_STORE_CONNECT_APP_ID` when release notes are used

Transporter is the default uploader. `--upload-tool altool` is available as a
fallback, but it depends on Apple's deprecated `altool` behavior and local key
configuration.

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
