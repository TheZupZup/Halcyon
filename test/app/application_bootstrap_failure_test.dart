import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/application_lifecycle.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/playback_session_persistence.dart';
import 'package:linthra/core/services/smart_precache_service.dart';
import 'package:linthra/data/database/linthra_database.dart';
import 'package:linthra/data/database/linthra_database_provider.dart';
import 'package:linthra/data/repositories/playback_session_store_provider.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/shared/widgets/artwork_image.dart';
import 'package:path/path.dart' as p;

import '../support/counting_audio_player.dart';
import '../support/lifecycle_test_graph.dart';
import '../support/recording_media_session.dart';
import '../support/recording_remote_control_receiver.dart';

/// The failure injected into a real `bootstrapApplication()` run. A distinct
/// type so the tests can assert the *original* error surfaces, not something
/// the cleanup threw on top of it.
class _BootstrapFailure implements Exception {
  const _BootstrapFailure(this.where);

  final String where;

  @override
  String toString() => 'bootstrap failed at $where';
}

/// Fails while the side-effect services are being started — after the media
/// session has attached, so the database, the audio engine, the playback
/// controllers and the remote-control receiver all exist by then.
Override _failEarly(_BootstrapFailure failure) =>
    smartPrecacheServiceProvider.overrideWith(
      (Ref<SmartPrecacheService> ref) => throw failure,
    );

/// Fails at the last bootstrap step — after the normalize-volume subscription
/// and both global artwork hooks have been installed.
Override _failLate(_BootstrapFailure failure) =>
    playbackSessionPersistenceProvider.overrideWith(
      (Ref<PlaybackSessionPersistence?> ref) => throw failure,
    );

/// A media session that attaches immediately and owns nothing.
///
/// Bootstrap's default binding reads the real host, so on a Linux machine
/// these tests would reach the real MPRIS session bus — a connection attempt
/// whose duration is the machine's business, not the test's, and long enough
/// on a loaded runner to leave bootstrap still in attach when a test that
/// times cleanup looks at it.
RecordingMediaSessionBinding _attachedSession() =>
    RecordingMediaSessionBinding(session: RecordingMediaSession());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('bootstrapApplication failure', () {
    test('cleans up what it already built and rethrows the original error',
        () async {
      const _BootstrapFailure failure =
          _BootstrapFailure('side-effect services');
      final CountingAudioPlayer player = CountingAudioPlayer();
      final RecordingRemoteControlReceiver receiver =
          RecordingRemoteControlReceiver();
      final ProviderContainer container = ProviderContainer(
        overrides: linuxLifecycleOverrides(
          audioPlayer: player,
          remoteControlReceiver: receiver,
          extra: <Override>[_failEarly(failure)],
        ),
      );
      final LinthraDatabase database = container.read(linthraDatabaseProvider);
      await openDatabase(database);
      final RecordingMediaSession session = RecordingMediaSession();

      await expectLater(
        bootstrapApplication(
          container,
          installPersistentArtworkCache: false,
          mediaSessionBinding: RecordingMediaSessionBinding(session: session),
        ),
        throwsA(same(failure)),
      );

      expect(player.disposeCount, 1);
      expect(player.disposeFinished, isTrue);
      expect(session.detachCount, 1,
          reason: 'a failed startup gives the media session back too — on '
              'Linux that is the MPRIS bus name');
      // The failure lands before the remote-control providers are read, so the
      // receiver was never built — and cleanup does not conjure it up in order
      // to dispose it.
      expect(receiver.disposeCount, 0);
      expect(await isDatabaseOpen(database), isFalse,
          reason: 'the database opened during the failed bootstrap is closed');
      expect(
        () => container.read(playbackControllerProvider),
        throwsStateError,
        reason: 'the container itself is disposed',
      );
    });

    test('a failure after the global hooks are installed still clears them',
        () async {
      final Directory cacheDirectory =
          await Directory.systemTemp.createTemp('linthra_bootstrap_artwork');
      addTearDown(() => cacheDirectory.delete(recursive: true));
      final Uri cover = Uri.parse('https://covers.test/late.png');
      final String hashed =
          sha256.convert(utf8.encode(cover.toString())).toString();
      File(p.join(cacheDirectory.path, '$hashed.img'))
          .writeAsBytesSync(<int>[1, 2, 3]);

      const _BootstrapFailure failure = _BootstrapFailure('session restore');
      final CountingAudioPlayer player = CountingAudioPlayer();
      final ProviderContainer container = ProviderContainer(
        overrides: linuxLifecycleOverrides(
          audioPlayer: player,
          extra: <Override>[_failLate(failure)],
        ),
      );

      await expectLater(
        bootstrapApplication(
          container,
          artworkCacheDirectory: cacheDirectory,
          mediaSessionBinding: _attachedSession(),
        ),
        throwsA(same(failure)),
      );

      expect(player.disposeCount, 1);
      // Neither global hook survives the failed attempt: the disk cache is
      // gone, and the resolver — which closed over the now-disposed container
      // — would throw here instead of resolving if it had been left behind.
      expect(artworkImageProvider(cover), isA<NetworkImage>());
      expect(
        artworkImageProvider(Uri.parse('subsonic-cover:1')),
        isA<NetworkImage>().having(
          (NetworkImage image) => image.url,
          'url',
          'subsonic-cover:1',
        ),
      );
    });

    test('waits for asynchronous cleanup before surfacing the failure',
        () async {
      const _BootstrapFailure failure = _BootstrapFailure('session restore');
      final Completer<void> gate = Completer<void>();
      final RecordingRemoteControlReceiver receiver =
          RecordingRemoteControlReceiver(disposeGate: gate);
      final ProviderContainer container = ProviderContainer(
        overrides: linuxLifecycleOverrides(
          audioPlayer: CountingAudioPlayer(),
          remoteControlReceiver: receiver,
          extra: <Override>[_failLate(failure)],
        ),
      );

      Object? caught;
      bool settled = false;
      final Future<void> attempt = bootstrapApplication(
        container,
        installPersistentArtworkCache: false,
        mediaSessionBinding: _attachedSession(),
      )
          .then<void>(
            (ApplicationHandle _) {},
            onError: (Object error) => caught = error,
          )
          .whenComplete(() => settled = true);

      await pumpEventQueue();
      expect(receiver.disposeStarted, isTrue);
      expect(settled, isFalse,
          reason:
              'the failure must not surface while cleanup is still running');

      gate.complete();
      await attempt;

      expect(caught, same(failure));
      expect(receiver.disposeFinished, isTrue);
      expect(receiver.commandsClosed, isTrue);
    });

    test('a second bootstrap initializes cleanly after a failed one', () async {
      const _BootstrapFailure failure =
          _BootstrapFailure('side-effect services');
      final CountingAudioPlayer firstPlayer = CountingAudioPlayer();
      final ProviderContainer firstContainer = ProviderContainer(
        overrides: linuxLifecycleOverrides(
          audioPlayer: firstPlayer,
          extra: <Override>[_failEarly(failure)],
        ),
      );
      final LinthraDatabase firstDatabase =
          firstContainer.read(linthraDatabaseProvider);
      await openDatabase(firstDatabase);

      await expectLater(
        bootstrapApplication(
          firstContainer,
          installPersistentArtworkCache: false,
          mediaSessionBinding: _attachedSession(),
        ),
        throwsA(same(failure)),
      );

      final CountingAudioPlayer secondPlayer = CountingAudioPlayer();
      final ProviderContainer secondContainer = ProviderContainer(
        overrides: linuxLifecycleOverrides(audioPlayer: secondPlayer),
      );

      final ApplicationHandle handle = await bootstrapApplication(
        secondContainer,
        installPersistentArtworkCache: false,
        mediaSessionBinding: _attachedSession(),
      );

      expect(await isDatabaseOpen(firstDatabase), isFalse);
      await openDatabase(secondContainer.read(linthraDatabaseProvider));
      expect(
        await isDatabaseOpen(secondContainer.read(linthraDatabaseProvider)),
        isTrue,
      );

      await secondContainer.read(playbackControllerProvider).playTrack(
            const Track(id: 'a', title: 'Song', uri: '/music/a.mp3'),
          );
      expect(
        secondContainer.read(playbackControllerProvider).state.status,
        PlaybackStatus.playing,
      );
      expect(firstPlayer.playCount, 0,
          reason: 'the failed attempt left nothing behind that still plays');

      await handle.shutdown();
      expect(secondPlayer.disposeCount, 1);
    });
  });
}
