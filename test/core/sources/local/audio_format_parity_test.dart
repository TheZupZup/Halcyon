import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/local/audio_file_types.dart';

void main() {
  test('Android SAF filename fallback matches Dart local audio formats', () {
    final File scanner = File(
      'android/app/src/main/kotlin/io/github/thezupzup/linthra/'
      'SafDocumentScanner.kt',
    );
    expect(
      scanner.existsSync(),
      isTrue,
      reason: 'SafDocumentScanner.kt must remain available for the parity guard',
    );

    final String source = scanner.readAsStringSync();
    final RegExpMatch? declaration = RegExp(
      r'private val AUDIO_EXTENSIONS\s*=\s*listOf\(([^)]*)\)',
      dotAll: true,
    ).firstMatch(source);

    expect(
      declaration,
      isNotNull,
      reason: 'The Android SAF extension fallback declaration must stay readable',
    );

    // Kotlin matches dotted filename suffixes (".flac"), while Dart stores the
    // same extensions without the dot. Compare the normalized sets so any
    // addition, removal, spelling change, or duplicate fails CI.
    final List<String> androidExtensions = RegExp(r'"(\.[^"]+)"')
        .allMatches(declaration!.group(1)!)
        .map((RegExpMatch match) => match.group(1)!.substring(1))
        .toList(growable: false);

    expect(
      androidExtensions.toSet(),
      hasLength(androidExtensions.length),
      reason: 'The Android SAF extension fallback must not contain duplicates',
    );
    expect(
      androidExtensions,
      unorderedEquals(AudioFileTypes.supportedExtensions),
      reason: 'Android SAF and Dart local-audio formats must stay in sync',
    );
  });
}
