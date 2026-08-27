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
      reason:
          'SafDocumentScanner.kt must remain available for the parity guard',
    );

    final String source = scanner.readAsStringSync();
    final RegExpMatch? declaration = RegExp(
      r'private val AUDIO_EXTENSIONS\s*=\s*listOf\(([^)]*)\)',
      dotAll: true,
    ).firstMatch(source);

    expect(
      declaration,
      isNotNull,
      reason:
          'The Android SAF extension fallback declaration must stay readable',
    );

    final List<String> androidRawExtensions = RegExp(r'"([^"]+)"')
        .allMatches(declaration!.group(1)!)
        .map((RegExpMatch match) => match.group(1)!)
        .toList(growable: false);

    expect(
      androidRawExtensions,
      isNotEmpty,
      reason: 'The Android SAF extension fallback must declare audio formats',
    );

    // Kotlin matches dotted filename suffixes (".flac"), while Dart stores the
    // same extensions without the dot. Validate every Kotlin entry before
    // normalizing so a malformed value such as "webm" cannot be silently
    // skipped by the parity guard.
    for (final String extension in androidRawExtensions) {
      expect(
        extension,
        matches(RegExp(r'^\.[^.]+$')),
        reason:
            'Android SAF extensions must start with exactly one dot: $extension',
      );
    }

    final List<String> androidExtensions = androidRawExtensions
        .map((String extension) => extension.substring(1))
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
