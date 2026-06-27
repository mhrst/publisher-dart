# publisher-dart

Dart scripts for publishing Inkpad internal Android and iOS builds.

The package is intended to replace the internal Fastlane lanes while keeping
the release flow explicit:

- bump the Flutter build number in `inkpad_app/pubspec.yaml`
- build the Android AAB or iOS archive
- upload to Google Play internal testing or App Store Connect
- optionally attach "what's new" / release notes
- leave the bumped version in the app worktree for manual commit/tagging

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

## Fresh release flow

Run from `inkpad-app/inkpad_app`. The expected order is Android first, then
iOS.

Before either platform:

- make sure Flutter dependencies are installed and the app builds locally
- prepare release notes with `--whats-new`, `--notes-file`, or
  `--stdin-release-notes`, if needed
- decide when you want to manually commit and tag the bumped version

The scripts do not create commits or tags. If you want a separate commit/tag for
each platform build, commit and tag manually after Android before starting iOS.
If you run both first, the iOS script will bump from Android's new version and
only the final iOS version remains in `pubspec.yaml`.

Each publisher increments the Flutter version before publishing. A fresh
Android-then-iOS run creates two consecutive build numbers. For example, if the
app starts at `6.5.0+6501`, Android publishes `6.5.0+6502`, then iOS publishes
`6.5.0+6503`.

### 1. Android

Prerequisites:

- Google Play Console access for `com.workpail.inkpad.notepad.notes` with
  release rights to the internal track
- an installed-app OAuth client JSON at
  `../_secrets/google-play-oauth-client.json`, or a path passed with
  `--oauth-client` / `GOOGLE_PLAY_OAUTH_CLIENT`
- a writable token cache path at
  `../_secrets/google-play-oauth-token.json`, or a path passed with
  `--oauth-token` / `GOOGLE_PLAY_OAUTH_TOKEN`
- Android signing configuration available to Gradle so Flutter can produce the
  release AAB

Fresh run:

```sh
make deploy_internal_android ARGS='--whats-new "Internal test build"'
```

What to expect the first time:

1. The script reads `pubspec.yaml` and bumps the version.
2. Flutter builds the release Android App Bundle.
3. A browser OAuth consent flow opens. Sign in with the Google account that has
   Play Console access. The script stores the refresh token in the token cache.
4. The AAB uploads to the Google Play internal track with the release notes, if
   provided.
5. The bumped `pubspec.yaml` remains in the app worktree. Commit and tag it
   manually before running iOS if you want the Android build recorded
   separately.

Later Android runs reuse the cached OAuth token. If Google does not return a
refresh token during setup, rerun with `--force-oauth-consent`.

### 2. iOS

Prerequisites:

- Xcode installed and signed in under Xcode > Settings > Accounts with an Apple
  Developer account that can sign and upload Inkpad
- App Store Connect access for `com.workpail.InkPad`
- an App Store Connect API key for draft metadata updates, with the key ID in
  `--app-store-key-id` / `APP_STORE_CONNECT_KEY_ID`
- the API private key at `../_secrets/app-store-connect-api-key.p8`, or a path
  passed with `--app-store-private-key` /
  `APP_STORE_CONNECT_PRIVATE_KEY`
- signing and provisioning configured so `xcodebuild archive` can complete

Fresh run:

```sh
make deploy_internal_ios ARGS='--whats-new "Internal test build"'
```

What to expect the first time:

1. The script reads `pubspec.yaml` and bumps the version.
2. Flutter prepares the iOS project, then `xcodebuild` archives and uploads with
   the Apple account installed in Xcode. Xcode or macOS may prompt for account,
   signing, or keychain access.
3. The upload is App Store distribution eligible and is not submitted for
   review.
4. The script uploads Crashlytics dSYMs unless symbol upload is skipped.
5. The script uses the App Store Connect API key to find the app, wait for build
   processing, attach the build to the matching App Store version draft, and
   update localized what's-new text when provided.
6. The bumped `pubspec.yaml` remains in the app worktree. Commit and tag it
   manually after verifying the upload.

Internal tester availability is controlled by the app's App Store Connect and
TestFlight configuration. The script uploads and updates draft metadata, but it
does not submit the app for review.

## Android

Android uses the Google Play Developer API directly through `googleapis` and
`googleapis_auth`. Authentication uses an installed-app OAuth client and a
cached user refresh token, not a service-account JSON. Defaults match the old
internal lane where they still apply:

- package name: `com.workpail.inkpad.notepad.notes`
- track: `internal`
- OAuth client JSON: `../_secrets/google-play-oauth-client.json`
- cached OAuth token: `../_secrets/google-play-oauth-token.json`

The first upload opens a browser consent flow and writes the token cache.
Later uploads refresh that token automatically. The signed-in Google account
must have Google Play Console access for the app.

OAuth paths can also be passed with options or env:

- `--oauth-client` or `GOOGLE_PLAY_OAUTH_CLIENT`
- `--oauth-token` or `GOOGLE_PLAY_OAUTH_TOKEN`

Useful options:

```sh
dart ../../publisher-dart/tool/publish_internal_android.dart \
  --whats-new "Internal test build"
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
  --whats-new "Internal test build"
```

## Safety switches

Both scripts support:

- `--dry-run`
- `--skip-build`
- `--skip-upload`
- `--bump build|patch|minor|major`
