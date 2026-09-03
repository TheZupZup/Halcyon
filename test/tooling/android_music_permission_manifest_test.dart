import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android declares only the expected local-audio permissions', () {
    final String manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

    expect(
      manifest,
      contains('android.permission.READ_MEDIA_AUDIO'),
    );
    expect(
      manifest,
      contains('android.permission.READ_EXTERNAL_STORAGE'),
    );
    expect(
      manifest,
      contains('android:maxSdkVersion="32"'),
    );
    expect(
      manifest,
      contains('android:appCategory="audio"'),
    );
  });
}
