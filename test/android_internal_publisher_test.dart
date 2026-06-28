import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:publisher_dart/publisher_dart.dart';
import 'package:test/test.dart';

void main() {
  test('updates existing Google Play release notes without uploading', () async {
    final requests = <http.Request>[];
    Object? updateTrackBody;

    final publisher = AndroidInternalPublisher(
      oauthCredentials: AndroidUserOAuthCredentials(
        clientSecretsFile: File('unused-client.json'),
        tokenStoreFile: File('unused-token.json'),
      ),
      createClient: ({required scopes}) async {
        expect(
          scopes,
          contains('https://www.googleapis.com/auth/androidpublisher'),
        );
        return MockClient((request) async {
          requests.add(request);

          return switch ((request.method, request.url.path)) {
            (
              'POST',
              '/androidpublisher/v3/applications/com.example.app/edits',
            ) =>
              _jsonResponse({'id': 'edit-123'}),
            (
              'GET',
              '/androidpublisher/v3/applications/com.example.app/edits/edit-123/tracks/internal',
            ) =>
              _jsonResponse({
                'track': 'internal',
                'releases': [
                  {
                    'name': 'older',
                    'status': 'completed',
                    'versionCodes': ['6501'],
                    'releaseNotes': [
                      {'language': 'en-US', 'text': 'Older notes'},
                    ],
                  },
                  {
                    'name': '6.5.0+6502',
                    'status': 'completed',
                    'versionCodes': ['6502'],
                    'releaseNotes': [
                      {'language': 'en-US', 'text': 'Wrong notes'},
                    ],
                  },
                ],
              }),
            (
              'PUT',
              '/androidpublisher/v3/applications/com.example.app/edits/edit-123/tracks/internal',
            ) =>
              () {
                updateTrackBody = jsonDecode(request.body);
                return _jsonResponse(updateTrackBody!);
              }(),
            (
              'POST',
              '/androidpublisher/v3/applications/com.example.app/edits/edit-123:commit',
            ) =>
              _jsonResponse({'id': 'edit-123'}),
            _ => http.Response(
              'unexpected ${request.method} ${request.url}',
              500,
            ),
          };
        });
      },
      appBundleFile: File('unused.aab'),
      packageName: 'com.example.app',
      trackName: 'internal',
      defaultReleaseNotesLocale: 'fr-FR',
      log: (_) {},
    );

    final versionCode = await publisher.updateReleaseNotes(
      version: AppVersion.parse('6.5.0+6502'),
      releaseNotes: ReleaseNotes.fromYaml('''
default: Corrected notes
es-419, es-MX: Notas corregidas
''')!,
    );

    expect(versionCode, 6502);
    expect(requests.map((request) => request.method), [
      'POST',
      'GET',
      'PUT',
      'POST',
    ]);

    expect(updateTrackBody, {
      'releases': [
        {
          'name': 'older',
          'releaseNotes': [
            {'language': 'en-US', 'text': 'Older notes'},
          ],
          'status': 'completed',
          'versionCodes': ['6501'],
        },
        {
          'name': '6.5.0+6502',
          'releaseNotes': [
            {'language': 'es-419', 'text': 'Notas corregidas'},
            {'language': 'fr-FR', 'text': 'Corrected notes'},
          ],
          'status': 'completed',
          'versionCodes': ['6502'],
        },
      ],
      'track': 'internal',
    });
  });
}

http.Response _jsonResponse(Object body, {int statusCode = 200}) {
  return http.Response(
    jsonEncode(body),
    statusCode,
    headers: {'content-type': 'application/json'},
  );
}
