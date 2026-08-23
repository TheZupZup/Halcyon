import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android verifier trusts the same certificate F-Droid pins', () {
    final String metadata = File(
      'metadata/io.github.thezupzup.linthra.yml',
    ).readAsStringSync();
    final RegExpMatch? match = RegExp(
      r'^AllowedAPKSigningKeys:\s*([0-9a-f]{64})\s*$',
      multiLine: true,
    ).firstMatch(metadata);

    expect(
      match,
      isNotNull,
      reason: 'F-Droid metadata must pin Linthra\'s release certificate.',
    );

    final String fingerprint = match!.group(1)!;
    final String verifier = File(
      'android/app/src/main/kotlin/io/github/thezupzup/linthra/BuildIntegrityChannel.kt',
    ).readAsStringSync();

    expect(
      verifier,
      contains(fingerprint),
      reason: 'BuildIntegrityChannel must trust the same public SHA-256 '
          'certificate fingerprint as F-Droid AllowedAPKSigningKeys. Update '
          'both deliberately if the release key is ever rotated.',
    );
  });
}
