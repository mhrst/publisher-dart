import 'dart:io';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';

final class AppStoreConnectCredentials {
  static const maxJwtLifetime = Duration(minutes: 20);

  final String keyId;
  final String issuerId;
  final File privateKeyFile;

  const AppStoreConnectCredentials({
    required this.keyId,
    required this.issuerId,
    required this.privateKeyFile,
  });

  Future<String> createJwt({Duration expiresIn = maxJwtLifetime}) async {
    if (expiresIn > maxJwtLifetime) {
      throw ArgumentError.value(
        expiresIn,
        'expiresIn',
        'App Store Connect tokens cannot live longer than 20 minutes.',
      );
    }

    final privateKey = await privateKeyFile.readAsString();
    final jwt = JWT(
      {'aud': 'appstoreconnect-v1', 'iss': issuerId},
      header: {'kid': keyId},
    );

    return jwt.sign(
      ECPrivateKey(privateKey),
      algorithm: JWTAlgorithm.ES256,
      expiresIn: expiresIn,
    );
  }
}
