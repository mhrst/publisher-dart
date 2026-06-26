# publisher-dart

Dart scripts for publishing Inkpad internal Android and iOS builds.

The package is intended to replace the internal Fastlane lanes while keeping
the release flow explicit:

- bump the Flutter build number in `inkpad_app/pubspec.yaml`
- build the Android AAB or iOS archive
- upload to Google Play internal testing or App Store Connect
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
signing and App Store Connect upload access for Inkpad. First make sure Xcode
can see the right account under Xcode > Settings > Accounts.

Uploaded builds are App Store distribution eligible and are not submitted for
review. App Store Connect/TestFlight can still make the processed build
available to internal testers according to the app's configured tester groups.

After upload, the script uses the App Store Connect API to wait for the build
to process, attach it to the matching App Store version draft, and optionally
update the draft's localized what's-new text. The script does not submit the
draft for review.

Draft metadata authentication uses a local App Store Connect API key. An
individual API key is recommended because it uses the developer's own App Store
Connect access and does not need an issuer ID. By default, the private key is
read from `../_secrets/app-store-connect-api-key.p8`.

Required metadata credentials:

- `--app-store-key-id` or `APP_STORE_CONNECT_KEY_ID`
- `--app-store-private-key` or `APP_STORE_CONNECT_PRIVATE_KEY`

Optional metadata settings:

- `--app-store-issuer-id` or `APP_STORE_CONNECT_ISSUER_ID` for a team API key
- `--app-store-app-id` or `APP_STORE_APP_ID`; otherwise the app is found by
  bundle ID
- `--bundle-id` or `APP_STORE_BUNDLE_ID`; defaults to `com.workpail.InkPad`
- `--metadata-locale` or `APP_STORE_CONNECT_LOCALE`; defaults to `en-US`

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
