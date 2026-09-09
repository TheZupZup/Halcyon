import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/persisted_playback_session.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/repeat_mode.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/playback_session_persistence.dart';
import 'package:linthra/core/sources/music_provider.dart';
import 'package:linthra/data/repositories/in_memory_playback_session_store.dart';

import '../../features/player/fake_playback_controller.dart';

void main() {
  const Track remote = Track(
    id: '101',
    title: 'Remote',
    uri: 'jellyfin:101',
    duration: Duration(minutes: 3),
  );
  const Track localMissing = Track(
    id: '/missing/song.mp3',
    title: 'Gone',
    uri: '/missing/song.mp3',
    duration: Duration(minutes: 2),
  );
  const Track localOk = Track(
    id: '/tmp/linthra-session-test.mp3',
    title: 'Ok',
    uri: '/tmp/linthra-session-test.mp3',
    duration: Duration(minutes: 2),
  );

  group('PlaybackSessionPersistence', () {
    test('persists a paused/playing state and restores it without autoplay',
        () async {
      final InMemoryPlaybackSessionStore store = InMemoryPlaybackSessionStore();
      final FakePlaybackController controller = FakePlaybackController();
      final PlaybackSessionPersistence persistence = PlaybackSessionPersistence(
        store: store,
        controller: controller,
        playbackStates: controller.stateStream,
        localFileExists: (_) => true,
        positionSaveInterval: Duration.zero,
      );

      controller.emit(const PlaybackState(
        status: PlaybackStatus.playing,
        currentTrack: remote,
        position: Duration(seconds: 33),
        duration: Duration(minutes: 3),
        upNext: <Track>[],
        previous: <Track>[],
      ));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final PersistedPlaybackSession? saved = await store.load();
      expect(saved, isNotNull);
      expect(saved!.current!.uri, remote.uri);
      expect(saved.position, const Duration(seconds: 33));

      final FakePlaybackController restoredController =
          FakePlaybackController();
      final PlaybackSessionPersistence restorer = PlaybackSessionPersistence(
        store: store,
        controller: restoredController,
        playbackStates: restoredController.stateStream,
        localFileExists: (_) => true,
      );
      await restorer.restore();

      expect(restoredController.restoreSessionCount, 1);
      expect(restoredController.lastRestoreAutoplay, isFalse);
      expect(
          restoredController.lastRestorePosition, const Duration(seconds: 33));
      expect(restoredController.state.status, PlaybackStatus.paused);
      expect(restoredController.state.currentTrack?.uri, remote.uri);
      expect(restoredController.state.isPlaying, isFalse);

      await persistence.dispose();
      await restorer.dispose();
      await controller.dispose();
      await restoredController.dispose();
    });

    test('drops signed-out remote tracks and missing local files on restore',
        () async {
      final InMemoryPlaybackSessionStore store = InMemoryPlaybackSessionStore(
        const PersistedPlaybackSession(
          tracks: <Track>[localMissing, remote, localOk],
          currentIndex: 1,
          position: Duration(seconds: 5),
        ),
      );
      final FakePlaybackController controller = FakePlaybackController();
      final PlaybackSessionPersistence persistence = PlaybackSessionPersistence(
        store: store,
        controller: controller,
        playbackStates: const Stream<PlaybackState>.empty(),
        isRemoteProviderAvailable: (MusicProvider p) =>
            !identical(p, MusicProviders.jellyfin),
        localFileExists: (String uri) => uri == localOk.uri,
      );

      await persistence.restore();

      expect(controller.restoreSessionCount, 1);
      expect(controller.state.currentTrack?.uri, localOk.uri);
      expect(controller.state.upNext, isEmpty);
      expect(controller.state.isPlaying, isFalse);

      await persistence.dispose();
      await controller.dispose();
    });

    test('a wholly invalid session is cleared and does not restore', () async {
      final InMemoryPlaybackSessionStore store = InMemoryPlaybackSessionStore(
        const PersistedPlaybackSession(
          tracks: <Track>[remote],
          currentIndex: 0,
        ),
      );
      final FakePlaybackController controller = FakePlaybackController();
      final PlaybackSessionPersistence persistence = PlaybackSessionPersistence(
        store: store,
        controller: controller,
        playbackStates: const Stream<PlaybackState>.empty(),
        isRemoteProviderAvailable: (_) => false,
        localFileExists: (_) => false,
      );

      await persistence.restore();

      expect(controller.restoreSessionCount, 0);
      expect(await store.load(), isNull);

      await persistence.dispose();
      await controller.dispose();
    });

    test('clears persistence when playback becomes idle without a track',
        () async {
      final InMemoryPlaybackSessionStore store = InMemoryPlaybackSessionStore();
      final FakePlaybackController controller = FakePlaybackController();
      final PlaybackSessionPersistence persistence = PlaybackSessionPersistence(
        store: store,
        controller: controller,
        playbackStates: controller.stateStream,
        localFileExists: (_) => true,
        positionSaveInterval: Duration.zero,
      );

      controller.emit(const PlaybackState(
        status: PlaybackStatus.paused,
        currentTrack: remote,
      ));
      await Future<void>.delayed(Duration.zero);
      expect(await store.load(), isNotNull);

      controller.emit(PlaybackState.idle);
      await Future<void>.delayed(Duration.zero);
      expect(await store.load(), isNull);

      await persistence.dispose();
      await controller.dispose();
    });

    test('restore failure clears the store and never throws', () async {
      final InMemoryPlaybackSessionStore store = InMemoryPlaybackSessionStore(
        const PersistedPlaybackSession(
          tracks: <Track>[remote],
          currentIndex: 0,
        ),
      );
      final _ThrowingRestoreController controller =
          _ThrowingRestoreController();
      final PlaybackSessionPersistence persistence = PlaybackSessionPersistence(
        store: store,
        controller: controller,
        playbackStates: const Stream<PlaybackState>.empty(),
        localFileExists: (_) => true,
      );

      await expectLater(persistence.restore(), completes);
      expect(await store.load(), isNull);

      await persistence.dispose();
      await controller.dispose();
    });
    test('a volume-only change on a paused track writes nothing', () async {
      // The session document has no volume or mute field, so re-saving it for
      // a slider step would be a disk write per pointer move.
      final _CountingStore store = _CountingStore();
      final FakePlaybackController controller = FakePlaybackController();
      final PlaybackSessionPersistence persistence = PlaybackSessionPersistence(
        store: store,
        controller: controller,
        playbackStates: controller.stateStream,
        localFileExists: (_) => true,
        positionSaveInterval: Duration.zero,
      );
      addTearDown(persistence.dispose);
      addTearDown(controller.dispose);

      controller.emit(const PlaybackState(
        status: PlaybackStatus.paused,
        currentTrack: remote,
        position: Duration(seconds: 12),
        duration: Duration(minutes: 3),
      ));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      final int afterFirst = store.saves;
      expect(afterFirst, greaterThan(0));

      controller.setVolume(0.6);
      controller.setVolume(0.5);
      controller.setMuted(true);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(store.saves, afterFirst);

      // A real move still persists.
      controller.emit(const PlaybackState(
        status: PlaybackStatus.paused,
        currentTrack: remote,
        position: Duration(seconds: 40),
        duration: Duration(minutes: 3),
      ));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(store.saves, greaterThan(afterFirst));
    });
  });
}

/// Local engine that throws from [restoreSession] so startup-safety can be
/// asserted without a real audio backend.
/// Counts saves, so a test can prove a state change wrote nothing rather than
/// only that the last document still looks right.
class _CountingStore extends InMemoryPlaybackSessionStore {
  int saves = 0;

  @override
  Future<void> save(PersistedPlaybackSession session) async {
    saves++;
    await super.save(session);
  }
}

class _ThrowingRestoreController extends FakePlaybackController {
  @override
  Future<void> restoreSession({
    required List<Track> tracks,
    int startIndex = 0,
    Duration position = Duration.zero,
    bool shuffleEnabled = false,
    RepeatMode repeatMode = RepeatMode.off,
    List<Track>? originalOrder,
  }) async {
    throw StateError('simulated restore failure');
  }
}
