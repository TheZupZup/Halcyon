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
      contains(
          '?: throw IllegalStateException("MediaStore query returned no cursor")'),
    );
  });

  test('MediaStore track numbers decode the disc-encoded thousands field', () {
    expect(channel, contains('val rawTrack = cursor.getInt(trackIndex)'));
    expect(channel, contains('(rawTrack % 1000).takeIf { it > 0 }'));
  });

  test('MediaStore rows carry a stable source-namespaced album id', () {
    expect(channel, contains('MediaStore.Audio.Media.ALBUM_ID'));
    expect(channel, contains(r'"android-mediastore:$albumId"'));
    expect(channel, contains('"albumId" to albumId'));
  });

  test('album ids are namespaced by storage volume where Android exposes it',
      () {
    // EXTERNAL_CONTENT_URI aggregates every external volume from Android 10 on,
    // and ALBUM_ID is only unique within one volume's database. Without the
    // volume in the key, an album on an SD card can collide with an unrelated
    // album on internal storage and the two get grouped as one.
    expect(channel, contains('MediaStore.Audio.Media.VOLUME_NAME'));
    expect(channel, contains(r'"android-mediastore:$volume:$albumId"'));
    // Guarded, because VOLUME_NAME does not exist below Android 10 and asking
    // for it there makes the whole query throw.
    expect(channel, contains('Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q'));
  });
}
