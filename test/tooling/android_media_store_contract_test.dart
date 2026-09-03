import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String channel;

  setUpAll(() {
    channel = File(
      'android/app/src/main/kotlin/io/github/thezupzup/linthra/'
      'AndroidMediaLibraryChannel.kt',
    ).readAsStringSync();
  });

  test('MediaStore scan fails closed when no cursor is returned', () {
    expect(
      channel,
      contains('?: throw IllegalStateException("MediaStore query returned no cursor")'),
    );
  });

  test('MediaStore track numbers decode the disc-encoded thousands field', () {
    expect(channel, contains('val rawTrack = cursor.getInt(trackIndex)'));
    expect(channel, contains('(rawTrack % 1000).takeIf { it > 0 }'));
  });

  test('MediaStore rows carry a stable source-namespaced album id', () {
    expect(channel, contains('MediaStore.Audio.Media.ALBUM_ID'));
    expect(channel, contains(r'"android-mediastore:$it"'));
    expect(channel, contains('"albumId" to albumId'));
  });
}
