import 'package:publisher_dart/publisher_dart.dart';
import 'package:test/test.dart';

void main() {
  test('parses Google installed-app OAuth client JSON', () {
    final clientId = GoogleOAuthClientId.fromJson({
      'installed': {
        'client_id': 'client-id.apps.googleusercontent.com',
        'client_secret': 'client-secret',
      },
    });

    expect(clientId.identifier, 'client-id.apps.googleusercontent.com');
    expect(clientId.secret, 'client-secret');
  });

  test('parses direct OAuth client JSON', () {
    final clientId = GoogleOAuthClientId.fromJson({
      'identifier': 'client-id.apps.googleusercontent.com',
      'secret': 'client-secret',
    });

    expect(clientId.identifier, 'client-id.apps.googleusercontent.com');
    expect(clientId.secret, 'client-secret');
  });

  test('rejects OAuth client JSON without a client id', () {
    expect(
      () => GoogleOAuthClientId.fromJson({'installed': <String, Object?>{}}),
      throwsFormatException,
    );
  });
}
