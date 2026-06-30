# publisher-dart

Dart scripts for publishing Flutter internal Android and iOS builds.

The scripts are designed to run from any Flutter app directory. By default they
read `pubspec.yaml`, `android/`, `ios/`, and `build/` from the current working
directory. Pass `--app-dir` only when you want to run from somewhere else.

The release flow stays explicit:

- read the Flutter version from the app's `pubspec.yaml`
- build the Android AAB or iOS archive
- upload to Google Play internal testing or App Store Connect
- optionally attach localized release notes
- leave version commits and tags fully manual

## Add To An App

Add this package to the Flutter app that will run the publisher:

```yaml
dev_dependencies:
  publisher_dart:
    path: /absolute/path/to/publisher-dart
```

Then run from that app directory:

```sh
dart pub get
dart run publisher_dart:publish_internal_android --help
dart run publisher_dart:publish_internal_ios --help
```

You can also wrap these commands in an app-local Makefile. Keep the working
directory as the Flutter app directory so the default `--app-dir .` resolves to
the app being published.

## Configuration

Public app-specific values are command options. Credential files, token paths,
and the IDs tied to those credentials can be supplied with environment
variables. The scripts do not read credentials from a fixed sibling secrets
directory.

Android requires:

- `--package-name`
- `--oauth-client` or `GOOGLE_PLAY_OAUTH_CLIENT`: path to the Google OAuth
  installed-app client JSON
- `--oauth-token` or `GOOGLE_PLAY_OAUTH_TOKEN`: writable path for the cached
  Google OAuth token JSON

Android optional settings:

- `--track`: Google Play testing track API name, defaulting to `internal`
- `--oauth-port`: localhost callback port for first-time OAuth consent,
  defaulting to a random available port
- `--release-notes-locale`, defaulting to `en-US`

iOS requires:

- `--team-id`

iOS what's-new updates also require:

- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_PRIVATE_KEY`: path to the App Store Connect API `.p8`
  private key
- `--bundle-id`, unless `--app-store-app-id` is set

iOS optional what's-new settings:

- `APP_STORE_CONNECT_ISSUER_ID` for a team API key
- `--app-store-app-id` to skip bundle ID lookup
- `--whats-new-locale`, defaulting to `en-US`
- `--build-poll-timeout` and `--build-poll-interval` for App Store Connect
  build processing checks

Example app-local credentials environment:

```sh
export GOOGLE_PLAY_OAUTH_CLIENT="$HOME/.config/example/google-play-oauth-client.json"
export GOOGLE_PLAY_OAUTH_TOKEN="$HOME/.config/example/google-play-oauth-token.json"
export APP_STORE_CONNECT_KEY_ID="ABC123DEFG"
export APP_STORE_CONNECT_ISSUER_ID="00000000-0000-0000-0000-000000000000"
export APP_STORE_CONNECT_PRIVATE_KEY="$HOME/.config/example/AuthKey_ABC123DEFG.p8"
```

## Fresh Release Flow

Before either platform:

- make sure Flutter dependencies are installed and the app builds locally
- manually update `pubspec.yaml` to the version/build number you want to
  publish
- prepare Android release notes with `--release-notes`,
  `--release-notes-file`, or `--release-notes-stdin`, if needed
- prepare iOS what's-new text with `--whats-new`, `--whats-new-file`, or
  `--whats-new-stdin`, if needed
- decide when you want to manually commit and tag the release

The scripts do not change `pubspec.yaml`, create commits, or create tags. They
use the version already in `pubspec.yaml`. If you want a separate version for
each platform build, update, commit, and tag manually between Android and iOS.

Android and iOS can use the same `pubspec.yaml` version, but each store still
requires a valid next build number for that platform. Google Play rejects an AAB
whose Android version code was already uploaded, and App Store Connect rejects a
build number that already exists for the same App Store version.

## Localized Release Notes

Android `--release-notes` / `--release-notes-stdin` and iOS `--whats-new` /
`--whats-new-stdin` provide one plain-text note. Android sends that note as
`--release-notes-locale`; iOS sends it to `--whats-new-locale`. Both default
to `en-US`.

For per-language notes, pass a `.yaml` file with `--release-notes-file` or
`--whats-new-file`:

```yaml
default: |
  Internal test build.
en-US: |
  Internal test build.
es-419, es-MX: |
  Version interna de prueba.
zh-CN, zh-Hans: |
  Internal test build.
```

Use a single locale key when both stores use the same code, such as `en-US`.
When the stores differ, use `android-locale, ios-locale`, such as
`es-419, es-MX` or `zh-CN, zh-Hans`. The script validates iOS locales against
the supported App Store locale list before making API calls. YAML locale keys
are uploaded as written; `--release-notes-locale` and `--whats-new-locale`
only control the fallback locale for plain text notes and YAML `default:`.

## Android

Android uses the Google Play Developer API directly through `googleapis` and
`googleapis_auth`. Authentication uses an installed-app OAuth client and a
cached user refresh token, not a service-account JSON.

Fresh run:

```sh
dart run publisher_dart:publish_internal_android \
  --package-name com.example.app \
  --release-notes "Internal test build"
```

What to expect the first time:

1. The script reads the current version from `pubspec.yaml`.
2. Flutter builds the release Android App Bundle.
3. A browser OAuth consent flow opens. Sign in with the Google account that has
   Play Console access.
4. The script stores the refresh token at `GOOGLE_PLAY_OAUTH_TOKEN` or the path
   passed with `--oauth-token`.
5. The AAB uploads to the configured Google Play track with release notes, if
   provided.
6. `pubspec.yaml` remains unchanged. Commit and tag the release manually when
   you are ready.

Later Android runs reuse the cached OAuth token. If Google does not return a
refresh token during setup, rerun with `--force-oauth-consent`.

If the internal release is already committed and only the release notes are
wrong, retry only that metadata update:

```sh
dart run publisher_dart:publish_internal_android \
  --package-name com.example.app \
  --only-release-notes \
  --release-notes "Corrected notes"
```

That retry reads the current `pubspec.yaml` build number, finds the matching
release on the Google Play track, replaces the specified localized release
notes, and commits the Play edit. It does not build or upload an AAB.

## iOS

iOS builds an App Store Connect archive and uploads it with `xcodebuild` using
the Apple Developer account already installed in Xcode. The account must have
signing and App Store Connect upload access for the app. First make sure Xcode
can see the right account under Xcode > Settings > Accounts.

Uploaded builds are App Store distribution eligible and are not submitted for
review. App Store Connect/TestFlight can still make the processed build
available to internal testers according to the app's configured tester groups.

After upload, the script uses the App Store Connect API to wait for the build
to process, attach it to the matching App Store version draft, and update
localized what's-new text when notes are provided.

Fresh run:

```sh
dart run publisher_dart:publish_internal_ios \
  --team-id ABCDE12345 \
  --bundle-id com.example.app \
  --whats-new "Internal test build"
```

What to expect the first time:

1. The script reads the current version from `pubspec.yaml`.
2. Flutter prepares the iOS project, then `xcodebuild` archives and uploads with
   the Apple account installed in Xcode. Xcode or macOS may prompt for account,
   signing, or keychain access.
3. The upload is App Store distribution eligible and is not submitted for
   review.
4. The script uploads Crashlytics dSYMs.
5. When what's-new text is provided, the script uses the App Store Connect API
   key to find the app, wait for build processing, attach the build to the
   matching App Store version draft, and update localized what's-new text.
6. `pubspec.yaml` remains unchanged. Commit and tag the release manually when
   you are ready.

If the upload succeeds but the App Store what's-new update fails, retry only
that step:

```sh
dart run publisher_dart:publish_internal_ios \
  --team-id ABCDE12345 \
  --bundle-id com.example.app \
  --only-whats-new \
  --whats-new "Internal test build"
```

That retry reads the current `pubspec.yaml` version, finds or creates the
matching App Store version draft, and updates localized what's-new text. It
does not build, upload, export an IPA, attach a build, or upload Crashlytics
symbols.

## Safety Switches

Both scripts support:

- `--dry-run`
- `--skip-build`
- `--skip-upload`

Android also supports:

- `--only-release-notes`

iOS also supports:

- `--only-whats-new`

## Reference Docs

- Google Play Developer API setup:
  https://developers.google.com/android-publisher/getting_started
- Google OAuth installed apps:
  https://developers.google.com/identity/protocols/oauth2/native-app
- App Store Connect API keys:
  https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/
- Apple Developer Team ID:
  https://developer.apple.com/help/account/manage-your-team/locate-your-team-id/
