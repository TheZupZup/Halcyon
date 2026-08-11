import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/lyric_focus.dart';

void main() {
  group('lyricEmphasisFor', () {
    test('the playing line is the active one', () {
      expect(
        lyricEmphasisFor(index: 4, activeIndex: 4),
        LyricEmphasis.active,
      );
    });

    test('emphasis falls off progressively either side of the active line', () {
      const int active = 10;
      expect(
        lyricEmphasisFor(index: active, activeIndex: active),
        LyricEmphasis.active,
      );
      expect(
        lyricEmphasisFor(index: active + 1, activeIndex: active),
        LyricEmphasis.adjacent,
      );
      expect(
        lyricEmphasisFor(index: active + 2, activeIndex: active),
        LyricEmphasis.near,
      );
      expect(
        lyricEmphasisFor(index: active + 3, activeIndex: active),
        LyricEmphasis.distant,
      );
      expect(
        lyricEmphasisFor(index: active + 40, activeIndex: active),
        LyricEmphasis.distant,
      );
    });

    test('the fade is symmetric: sung lines recede like upcoming ones', () {
      const int active = 10;
      for (int distance = 0; distance <= 4; distance++) {
        expect(
          lyricEmphasisFor(index: active - distance, activeIndex: active),
          lyricEmphasisFor(index: active + distance, activeIndex: active),
          reason: 'distance $distance must read the same either side',
        );
      }
    });

    test('before the first timed line nothing is highlighted', () {
      // Lyrics.activeLineIndex reports -1 during an instrumental intro. Every
      // line must then read the same — inventing an "active" line would be a
      // lie about where playback is.
      for (final int index in <int>[0, 1, 2, 9]) {
        expect(
          lyricEmphasisFor(index: index, activeIndex: -1),
          LyricEmphasis.near,
        );
      }
    });
  });
}
