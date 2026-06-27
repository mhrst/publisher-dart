# publisher-dart

Dart scripts for publishing Inkpad internal Android and iOS builds.

The package is intended to replace the internal Fastlane lanes while keeping
the release flow explicit:

- read the Flutter version from `inkpad_app/pubspec.yaml`
- build the Android AAB or iOS archive
- upload to Google Play internal testing or App Store Connect
- optionally attach "what's new" / release notes
- leave version commits and tags fully manual

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
- manually update `inkpad_app/pubspec.yaml` to the version/build number you
  want to publish
- prepare release notes with `--whats-new`, `--notes-file`, or
  `--stdin-release-notes`, if needed
- decide when you want to manually commit and tag the release

The scripts do not change `pubspec.yaml`, create commits, or create tags. They
use the version already in `pubspec.yaml`. If you want a separate version for
each platform build, update, commit, and tag manually between Android and iOS.

Android and iOS can use the same `pubspec.yaml` version, but each store still
requires a valid next build number for that platform. Google Play rejects an AAB
whose Android version code was already uploaded, and App Store Connect rejects a
build number that already exists for the same App Store version.

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

1. The script reads the current version from `pubspec.yaml`.
2. Flutter builds the release Android App Bundle.
3. A browser OAuth consent flow opens. Sign in with the Google account that has
   Play Console access. The script stores the refresh token in the token cache.
4. The AAB uploads to the Google Play internal track with the release notes, if
   provided.
5. `pubspec.yaml` remains unchanged. Commit and tag the release manually when
   you are ready.

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

1. The script reads the current version from `pubspec.yaml`.
2. Flutter prepares the iOS project, then `xcodebuild` archives and uploads with
   the Apple account installed in Xcode. Xcode or macOS may prompt for account,
   signing, or keychain access.
3. The upload is App Store distribution eligible and is not submitted for
   review.
4. The script uploads Crashlytics dSYMs unless symbol upload is skipped.
5. The script uses the App Store Connect API key to find the app, wait for build
   processing, attach the build to the matching App Store version draft, and
   update localized what's-new text when provided.
6. `pubspec.yaml` remains unchanged. Commit and tag the release manually when
   you are ready.

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

Where to get Android values:

- `package-name`: the Android application ID / Google Play package name. This
  defaults to `com.workpail.inkpad.notepad.notes`.
- `track`: the Google Play testing track API name. Internal testing is
  `internal`.
- `--oauth-client` / `GOOGLE_PLAY_OAUTH_CLIENT`: use the Google Cloud project
  connected to Google Play Console API access, enable the Google Play Android
  Developer API, then go to Google Cloud Console > APIs & Services >
  Credentials > Create credentials > OAuth client ID > Desktop app. Download
  the client JSON and save it as
  `../_secrets/google-play-oauth-client.json`, or pass its path.
- `--oauth-token` / `GOOGLE_PLAY_OAUTH_TOKEN`: choose a local path for the
  cached user token. The script creates this file after the first browser
  consent flow; it is not downloaded from Google.
- browser sign-in account: use the Google account that has Play Console access
  to the Inkpad app and permission to publish to the internal track.

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

Where to get iOS values:

- Xcode account: sign in at Xcode > Settings > Accounts with the Apple
  Developer account that can sign and upload Inkpad.
- `--team-id`: the Apple Developer Team ID. Find it in the Apple Developer
  account membership details or in Xcode's account/team details. The default is
  `TUPCVWUMEF`.
- `--app-store-key-id` / `APP_STORE_CONNECT_KEY_ID`: in App Store Connect, open
  your account profile / Edit Profile and create an Individual API Key. The key
  ID is shown with the generated key. For a team key, use App Store Connect >
  Users and Access > Integrations > App Store Connect API.
- `--app-store-private-key` / `APP_STORE_CONNECT_PRIVATE_KEY`: the local path
  to the `.p8` private key downloaded when creating the App Store Connect API
  key. Apple only allows the private key to be downloaded at creation time; save
  it as `../_secrets/app-store-connect-api-key.p8` or pass its path.
- `--app-store-issuer-id` / `APP_STORE_CONNECT_ISSUER_ID`: only needed for a
  team API key. Copy it from the App Store Connect API keys page. Leave it
  unset for an Individual API Key.
- `--app-store-app-id` / `APP_STORE_APP_ID`: optional numeric App Store Connect
  app ID. Open the Inkpad app in App Store Connect and copy the number from the
  `/apps/<id>/...` URL. If omitted, the script looks up the app by bundle ID.
- `--bundle-id` / `APP_STORE_BUNDLE_ID`: the iOS bundle identifier from the
  Xcode Runner target or App Store Connect app information. This defaults to
  `com.workpail.InkPad`.
- `--metadata-locale` / `APP_STORE_CONNECT_LOCALE`: the App Store version
  localization to update, such as `en-US`. Use the locale configured for the
  draft version in App Store Connect.

```sh
dart ../../publisher-dart/tool/publish_internal_ios.dart \
  --whats-new "Internal test build"
```

Reference docs:

- Google Play Developer API setup:
  https://developers.google.com/android-publisher/getting_started
- Google OAuth installed apps:
  https://developers.google.com/identity/protocols/oauth2/native-app
- App Store Connect API keys:
  https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/
- Apple Developer Team ID:
  https://developer.apple.com/help/account/manage-your-team/locate-your-team-id/

## Safety switches

Both scripts support:

- `--dry-run`
- `--skip-build`
- `--skip-upload`
