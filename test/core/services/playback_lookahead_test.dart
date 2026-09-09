import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/repeat_mode.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/playback_lookahead.dart';

Track _t(String id, {String provider = 'jellyfin'}) =>
    Track(id: id, title: id, uri: '$provider:$id');

PlaybackState _state(
  Track? current,
  List<Track> upNext, {
  Duration position = Duration.zero,
  bool shuffle = false,
  RepeatMode repeat = RepeatMode.off,
  PlaybackStatus status = PlaybackStatus.playing,
}) =>
    PlaybackState(
      status: status,
      currentTrack: current,
      upNext: upNext,
      position: position,
      shuffleEnabled: shuffle,
      repeatMode: repeat,
    );

void main() {
  group('samePlaybackLookahead', () {
    test('a position tick is the same work', () {
      final List<Track> upNext = <Track>[_t('2'), _t('3')];
      final PlaybackState first = _state(_t('1'), upNext);
      // Exactly how the controller emits a tick: the queue objects are handed
      // through untouched, only the position moves.
      final PlaybackState tick =
          first.copyWith(position: const Duration(seconds: 7));

      expect(samePlaybackLookahead(first, tick, ahead: 3), isTrue);
    });

    test('a status change alone is the same work', () {
      final PlaybackState playing = _state(_t('1'), <Track>[_t('2')]);
      final PlaybackState paused =
          playing.copyWith(status: PlaybackStatus.paused);

      expect(samePlaybackLookahead(playing, paused, ahead: 3), isTrue);
    });

    test('a null state never matches, so the first emission always runs', () {
      final PlaybackState state = _state(_t('1'), <Track>[_t('2')]);

      expect(samePlaybackLookahead(state, null, ahead: 3), isFalse);
      expect(samePlaybackLookahead(null, state, ahead: 3), isFalse);
    });

    test('a track change is different work', () {
      final List<Track> upNext = <Track>[_t('2')];

      expect(
        samePlaybackLookahead(
          _state(_t('1'), upNext),
          _state(_t('9'), upNext),
          ahead: 3,
        ),
        isFalse,
      );
    });

    test('a same-id copy from another provider is different work', () {
      // The fallback that swaps jellyfin:101 for subsonic:101 keeps the bare id
      // but is a different copy to warm.
      expect(
        samePlaybackLookahead(
          _state(_t('101'), const <Track>[]),
          _state(_t('101', provider: 'subsonic'), const <Track>[]),
          ahead: 3,
        ),
        isFalse,
      );
    });

    test('shuffle and repeat changes are different work', () {
      final Track current = _t('1');
      final List<Track> upNext = <Track>[_t('2')];

      expect(
        samePlaybackLookahead(
          _state(current, upNext),
          _state(current, upNext, shuffle: true),
          ahead: 3,
        ),
        isFalse,
      );
      expect(
        samePlaybackLookahead(
          _state(current, upNext),
          _state(current, upNext, repeat: RepeatMode.one),
          ahead: 3,
        ),
        isFalse,
      );
    });

    test('a rebuilt but equal queue still compares as the same work', () {
      // Identity is only the fast path; equal contents must still match, or a
      // queue rebuilt for unrelated reasons would re-trigger a warm.
      expect(
        samePlaybackLookahead(
          _state(_t('1'), <Track>[_t('2'), _t('3')]),
          _state(_t('1'), <Track>[_t('2'), _t('3')]),
          ahead: 3,
        ),
        isTrue,
      );
    });

    test('a change inside the look-ahead is different work', () {
      expect(
        samePlaybackLookahead(
          _state(_t('1'), <Track>[_t('2'), _t('3')]),
          _state(_t('1'), <Track>[_t('2'), _t('4')]),
          ahead: 3,
        ),
        isFalse,
      );
    });

    test('a change past the look-ahead is not work at all', () {
      // Only the head of up-next is ever warmed, so a queue edit 50 tracks out
      // must not wake anything up.
      final List<Track> head = <Track>[_t('2'), _t('3')];
      expect(
        samePlaybackLookahead(
          _state(_t('1'), <Track>[...head, _t('50')]),
          _state(_t('1'), <Track>[...head, _t('51')]),
          ahead: 2,
        ),
        isTrue,
      );
    });

    test('a shorter queue is different work even past the look-ahead', () {
      // Reaching the end of the queue matters: there is nothing left to warm.
      expect(
        samePlaybackLookahead(
          _state(_t('1'), <Track>[_t('2'), _t('3')]),
          _state(_t('1'), <Track>[_t('2')]),
          ahead: 5,
        ),
        isFalse,
      );
    });
  });
}
