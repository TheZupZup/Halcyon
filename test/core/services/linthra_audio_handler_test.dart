import 'dart:async';

import 'package:audio_service/audio_service.dart' as audio;
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/repeat_mode.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/download_store.dart';
import 'package:linthra/core/services/linthra_audio_handler.dart';
import 'package:linthra/core/services/media_artwork_source.dart';
import 'package:linthra/core/services/media_browser_tree.dart';

import '../../features/library/fake_music_library_repository.dart';
import '../../features/player/fake_playback_controller.dart';
import 'fake_browse_repositories.dart';

/// A synchronous [MediaArtworkSource] that returns the covers it's been warmed
/// with and records every lookup, so tests can prove the handler reads the cache
/// by the credential-free reference (and not at all for platform-loadable art).
class _RecordingArtworkSource implements MediaArtworkSource {
  _RecordingArtworkSource([Map<Uri, Uri>? cache])
      : _cache = cache ?? <Uri, Uri>{};

  final Map<Uri, Uri> _cache;
  final List<Uri> queries = <Uri>[];
  final StreamController<Uri> _coverReady = StreamController<Uri>.broadcast();

  /// Simulates the prewarm service finishing a fetch for [reference]: the cover
  /// becomes cached and the ready event fires (as the real cache does).
  void warm(Uri reference, Uri local) {
    _cache[reference] = local;
    _coverReady.add(reference);
  }

  @override
  Uri? cached(Uri reference) {
    queries.add(reference);
    return _cache[reference];
  }

  @override
  Stream<Uri> get coverReady => _coverReady.stream;

  Future<void> close() => _coverReady.close();
}

Track _track(String id) {
  return Track(
    id: id,
    title: 'Song $id',
    uri: '/$id.mp3',
    artistName: 'Artist $id',
    albumName: 'Album $id',
  );
}

final List<Track> _library = <Track>[_track('a'), _track('b'), _track('c')];

/// Lets the broadcast from the controller's stream reach the handler's
/// listener before assertions read the mirrored session state.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('LinthraAudioHandler', () {
    late FakePlaybackController controller;
    late LinthraAudioHandler handler;

    setUp(() {
      controller = FakePlaybackController();
      final library = FakeMusicLibraryRepository(tracks: _library);
      handler = LinthraAudioHandler(controller, MediaBrowserTree(library));
    });

    tearDown(() async {
      await handler.dispose();
      await controller.dispose();
    });

    test('forwards transport commands to the controller', () async {
      await handler.play();
      await handler.pause();
      await handler.skipToNext();
      await handler.skipToPrevious();
      await handler.stop();
      await handler.seek(const Duration(seconds: 12));

      expect(controller.playCount, 1);
      expect(controller.pauseCount, 1);
      expect(controller.skipCount, 1);
      expect(controller.previousCount, 1);
      expect(controller.stopCount, 1);
      expect(controller.seeks, [const Duration(seconds: 12)]);
    });

    test('mirrors the current track into the media item', () async {
      await controller.playTracks([_track('a'), _track('b')]);
      await _settle();

      final item = handler.mediaItem.value;
      expect(item, isNotNull);
      expect(item!.id, 'a');
      expect(item.title, 'Song a');
      expect(item.artist, 'Artist a');
      expect(item.album, 'Album a');
    });

    group('media-session artwork stays loadable (no opaque refs reach artUri)',
        () {
      Future<Uri?> artUriFor(Uri? artworkUri) async {
        await controller.playTracks(<Track>[
          Track(
              id: 'x',
              title: 'Song',
              uri: 'subsonic:x',
              artworkUri: artworkUri),
        ]);
        await _settle();
        return handler.mediaItem.value?.artUri;
      }

      test('drops an opaque subsonic-cover: reference to null', () async {
        // The OS fetches MediaItem.artUri itself and can't reach the in-app
        // resolver, so a custom-scheme reference must not reach the session (it
        // would fail/log on the bad URI); null cleanly shows no art, as before.
        expect(await artUriFor(Uri.parse('subsonic-cover:al-1')), isNull);
      });

      test('passes a Jellyfin token-free http(s) cover through', () async {
        final art = Uri.parse('https://jelly.example/Items/1/Images/Primary');
        expect(await artUriFor(art), art);
      });

      test('passes a local file: embedded cover through', () async {
        final art = Uri.parse('file:///cache/linthra_local_artwork/a.img');
        expect(await artUriFor(art), art);
      });
    });

    test('queue: state is ready with pause, stop and skip controls', () async {
      await controller.playTracks([_track('a'), _track('b')]);
      await _settle();

      final state = handler.playbackState.value;
      expect(state.playing, isTrue);
      expect(state.processingState, audio.AudioProcessingState.ready);
      expect(state.controls, contains(audio.MediaControl.pause));
      expect(state.controls, contains(audio.MediaControl.stop));
      expect(state.controls, contains(audio.MediaControl.skipToNext));
    });

    test('omits the skip control when nothing is queued next', () async {
      await controller.playTracks([_track('a')]);
      await _settle();

      final state = handler.playbackState.value;
      expect(state.controls, isNot(contains(audio.MediaControl.skipToNext)));
    });

    test('exposes skipToPrevious only once a previous track exists', () async {
      await controller.playTracks([_track('a'), _track('b')]);
      await _settle();
      expect(
        handler.playbackState.value.controls,
        isNot(contains(audio.MediaControl.skipToPrevious)),
      );

      await controller.skipToNext();
      await _settle();
      expect(
        handler.playbackState.value.controls,
        contains(audio.MediaControl.skipToPrevious),
      );
    });

    test('clears the media item when playback goes idle', () async {
      await controller.playTracks([_track('a')]);
      await _settle();
      expect(handler.mediaItem.value, isNotNull);

      controller.emit(PlaybackState.idle);
      await _settle();

      expect(handler.mediaItem.value, isNull);
      expect(handler.playbackState.value.playing, isFalse);
      expect(
        handler.playbackState.value.processingState,
        audio.AudioProcessingState.idle,
      );
    });

    group('session updates are not flooded by position ticks', () {
      test('the media item is pushed once per track, not per position tick',
          () async {
        final List<audio.MediaItem?> items = <audio.MediaItem?>[];
        final sub = handler.mediaItem.listen(items.add);
        addTearDown(sub.cancel);

        await controller.playTracks(<Track>[_track('a'), _track('b')]);
        await _settle();
        // Four position-only updates for the same track, each well under a
        // second apart — exactly what the engine's position stream produces.
        for (int ms = 200; ms <= 800; ms += 200) {
          controller.emit(
            controller.state.copyWith(position: Duration(milliseconds: ms)),
          );
          await _settle();
        }

        // Only one real item (track 'a') reached the session despite the ticks.
        final List<audio.MediaItem> nonNull =
            items.whereType<audio.MediaItem>().toList();
        expect(nonNull, hasLength(1));
        expect(nonNull.single.id, 'a');
      });

      test('playback state is not re-pushed on sub-second position ticks',
          () async {
        await controller.playTracks(<Track>[_track('a')]);
        await _settle();

        final List<audio.PlaybackState> pushed = <audio.PlaybackState>[];
        final sub = handler.playbackState.listen(pushed.add);
        addTearDown(sub.cancel);
        await _settle();
        // Listening replays the current value; count only pushes after that.
        final int baseline = pushed.length;

        for (int ms = 100; ms <= 900; ms += 200) {
          controller.emit(
            controller.state.copyWith(position: Duration(milliseconds: ms)),
          );
          await _settle();
        }

        // Same shape, drift under the 1s threshold: nothing new was pushed —
        // audio_service interpolates the displayed position between pushes.
        expect(pushed.length, baseline);
      });

      test('a position jump (a seek) is pushed immediately', () async {
        await controller.playTracks(<Track>[_track('a')]);
        await _settle();

        final List<audio.PlaybackState> pushed = <audio.PlaybackState>[];
        final sub = handler.playbackState.listen(pushed.add);
        addTearDown(sub.cancel);
        await _settle();
        final int baseline = pushed.length;

        // A discontinuity (>1s) is a seek/track reset and must re-sync.
        controller.emit(
          controller.state.copyWith(position: const Duration(seconds: 30)),
        );
        await _settle();

        expect(pushed.length, greaterThan(baseline));
      });

      test('a pause is pushed even when the position is steady', () async {
        await controller.playTracks(<Track>[_track('a')]);
        await _settle();

        final List<audio.PlaybackState> pushed = <audio.PlaybackState>[];
        final sub = handler.playbackState.listen(pushed.add);
        addTearDown(sub.cancel);
        await _settle();
        final int baseline = pushed.length;

        // Same position, different shape (paused): a control change always pushes.
        controller.emit(
          controller.state.copyWith(status: PlaybackStatus.paused),
        );
        await _settle();

        expect(pushed.length, greaterThan(baseline));
        expect(pushed.last.playing, isFalse);
      });
    });

    group('foreground service stays alive across buffering & transitions', () {
      // The screen-off bug: if the session reported `playing: false` during a
      // mid-stream re-buffer or a track transition, audio_service would demote
      // the foreground service and the OS could freeze the backgrounded process,
      // silencing playback until the app is reopened. So the session must stay
      // `playing` whenever the engine is working toward sound.

      test('a mid-stream re-buffer stays playing (service not demoted)',
          () async {
        await controller.playTracks(<Track>[_track('a')]);
        await _settle();

        controller.emit(
          controller.state.copyWith(status: PlaybackStatus.buffering),
        );
        await _settle();

        final state = handler.playbackState.value;
        expect(state.playing, isTrue);
        expect(state.processingState, audio.AudioProcessingState.buffering);
        // The toggle still offers pause (not play) while buffering.
        expect(state.controls, contains(audio.MediaControl.pause));
        expect(state.controls, isNot(contains(audio.MediaControl.play)));
      });

      test('a loading track transition stays playing', () async {
        await controller.playTracks(<Track>[_track('a')]);
        await _settle();

        controller.emit(
          controller.state.copyWith(status: PlaybackStatus.loading),
        );
        await _settle();

        final state = handler.playbackState.value;
        expect(state.playing, isTrue);
        expect(state.processingState, audio.AudioProcessingState.loading);
      });

      test('a car skip that loads the next track stays playing', () async {
        // A skip (from the car/notification, screen off) briefly enters loading
        // while the next track opens. The session must stay `playing` so the
        // foreground service isn't demoted mid-transition — and the media item
        // must already reflect the track being loaded.
        await controller.playTracks(<Track>[_track('a'), _track('b')]);
        await _settle();

        controller.emit(controller.state.copyWith(
          currentTrack: _track('b'),
          status: PlaybackStatus.loading,
        ));
        await _settle();

        final state = handler.playbackState.value;
        expect(state.playing, isTrue);
        expect(state.processingState, audio.AudioProcessingState.loading);
        expect(handler.mediaItem.value?.id, 'b');
      });

      test('a real user pause reports not-playing', () async {
        await controller.playTracks(<Track>[_track('a')]);
        await _settle();

        controller.emit(
          controller.state.copyWith(status: PlaybackStatus.paused),
        );
        await _settle();

        final state = handler.playbackState.value;
        expect(state.playing, isFalse);
        expect(state.controls, contains(audio.MediaControl.play));
        expect(state.controls, isNot(contains(audio.MediaControl.pause)));
      });

      test('completion and error report not-playing', () async {
        await controller.playTracks(<Track>[_track('a')]);
        await _settle();

        controller.emit(
          controller.state.copyWith(status: PlaybackStatus.completed),
        );
        await _settle();
        expect(handler.playbackState.value.playing, isFalse);
        expect(
          handler.playbackState.value.processingState,
          audio.AudioProcessingState.completed,
        );

        controller.emit(
          controller.state.copyWith(status: PlaybackStatus.error),
        );
        await _settle();
        expect(handler.playbackState.value.playing, isFalse);
      });
    });

    group('media browser', () {
      test('root lists the library categories and Queue', () async {
        final children = await handler.getChildren(MediaId.root);

        // No playlists/favorites/downloads wired here, so just the always-on
        // library categories plus Queue.
        expect(children.map((i) => i.id), [
          MediaId.library,
          MediaId.albums,
          MediaId.artists,
          MediaId.queue,
        ]);
        expect(children.map((i) => i.title),
            ['Songs', 'Albums', 'Artists', 'Queue']);
        expect(children.every((i) => i.playable == false), isTrue);
      });

      test('library lists every catalog track as a playable leaf', () async {
        final children = await handler.getChildren(MediaId.library);

        // Leaves are keyed by a hash of the uri; libraryTrack() hashes, so we
        // compare to it built from each track's uri (/<id>.mp3 here).
        expect(children.map((i) => i.id), [
          MediaId.libraryTrack('/a.mp3'),
          MediaId.libraryTrack('/b.mp3'),
          MediaId.libraryTrack('/c.mp3'),
        ]);
        expect(children.first.title, 'Song a');
        expect(children.first.playable, isTrue);
      });

      test('albums are browsable containers; opening one lists playable tracks',
          () async {
        final albums = await handler.getChildren(MediaId.albums);
        // Each _track('x') has album 'Album x', so there is one album per track.
        expect(albums, hasLength(3));
        expect(albums.every((i) => i.playable == false), isTrue);

        final tracks = await handler.getChildren(albums.first.id);
        expect(tracks, isNotEmpty);
        expect(tracks.every((i) => i.playable == true), isTrue);
      });

      test('selecting an album track plays the album queue', () async {
        final albums = await handler.getChildren(MediaId.albums);
        final albumTracks = await handler.getChildren(albums.first.id);

        await handler.playFromMediaId(albumTracks.first.id);
        await _settle();

        expect(controller.state.currentTrack, isNotNull);
        expect(controller.playedTracks, isNotEmpty);
      });

      test(
          'artists are browsable containers; opening one lists playable tracks',
          () async {
        final artists = await handler.getChildren(MediaId.artists);
        expect(artists, hasLength(3));
        expect(artists.every((i) => i.playable == false), isTrue);

        final tracks = await handler.getChildren(artists.first.id);
        expect(tracks, isNotEmpty);
        expect(tracks.every((i) => i.playable == true), isTrue);
      });

      test('queue reflects the controller current track and up-next', () async {
        await controller.playTracks(_library, startIndex: 1);
        await _settle();

        final children = await handler.getChildren(MediaId.queue);

        // current (b) followed by up-next (c).
        expect(children.map((i) => i.title), ['Song b', 'Song c']);
        expect(children.map((i) => i.id), [
          MediaId.queueItem(0),
          MediaId.queueItem(1),
        ]);
      });

      test('selecting a library track plays it and queues the rest', () async {
        await handler.playFromMediaId(MediaId.libraryTrack('/b.mp3'));
        await _settle();

        expect(controller.state.currentTrack?.id, 'b');
        expect(controller.state.upNext.map((t) => t.id), ['c']);
      });

      test('selecting a queue item plays from that position', () async {
        await controller.playTracks(_library);
        await _settle();

        await handler.playFromMediaId(MediaId.queueItem(2));
        await _settle();

        expect(controller.state.currentTrack?.id, 'c');
        expect(controller.state.hasNext, isFalse);
      });

      test('an unknown media id is a no-op', () async {
        await handler.playFromMediaId('library/missing');
        await handler.playFromMediaId('bogus');
        await _settle();

        expect(controller.playedTracks, isEmpty);
      });
    });

    // Regression coverage for #539, at the audio_service boundary: whatever the
    // browse tree decides, the MediaItems this handler hands to
    // MediaBrowserServiceCompat must stay a bounded, complete, playable-vs-
    // browsable-correct set — that list is delivered to Android Auto in one
    // Binder transaction, and an oversized one is dropped silently, leaving the
    // car spinning forever.
    group('large Songs catalogs page instead of flooding the browser (#539)',
        () {
      const int pageSize = MediaBrowserTree.browsePageSize;

      List<Track> catalog(int n) => <Track>[
            for (int i = 0; i < n; i++)
              Track(
                id: 'jellyfin:$i',
                title: 'Song ${i.toString().padLeft(5, '0')}',
                uri: 'jellyfin:https://host.example/Items/$i?api_key=SECRET',
                artistName: 'Artist ${i % 40}',
                albumName: 'Album ${i % 90}',
              ),
          ];

      /// A handler over [tracks], torn down with the test.
      LinthraAudioHandler handlerFor(List<Track> tracks) {
        final controller = FakePlaybackController();
        final handler = LinthraAudioHandler(
          controller,
          MediaBrowserTree(FakeMusicLibraryRepository(tracks: tracks)),
        );
        addTearDown(() async {
          await handler.dispose();
          await controller.dispose();
        });
        return handler;
      }

      /// Every playable MediaItem reachable under [parentId], descending
      /// through page containers.
      Future<List<audio.MediaItem>> leaves(
        LinthraAudioHandler handler,
        String parentId,
      ) async {
        final out = <audio.MediaItem>[];
        for (final audio.MediaItem item
            in await handler.getChildren(parentId)) {
          if (MediaId.isBrowsePage(item.id)) {
            out.addAll(await leaves(handler, item.id));
          } else {
            out.add(item);
          }
        }
        return out;
      }

      test('no getChildren response exceeds the browse bound', () async {
        final handler = handlerFor(catalog(4 * pageSize + 7));

        final top = await handler.getChildren(MediaId.library);
        expect(top.length, lessThanOrEqualTo(pageSize));
        for (final page in top) {
          expect((await handler.getChildren(page.id)).length,
              lessThanOrEqualTo(pageSize));
        }
      });

      test('every song still reaches Android Auto exactly once', () async {
        final tracks = catalog(4 * pageSize + 7);
        final handler = handlerFor(tracks);

        final items = await leaves(handler, MediaId.library);

        expect(items, hasLength(tracks.length));
        expect(items.map((i) => i.id).toSet(), hasLength(tracks.length));
        expect(items.map((i) => i.id),
            tracks.map((t) => MediaId.libraryTrack(t.uri)));
        expect(items.every((i) => i.playable == true), isTrue);
      });

      test('page rows are browsable containers, not playable items', () async {
        final handler = handlerFor(catalog(4 * pageSize + 7));

        final top = await handler.getChildren(MediaId.library);

        expect(top, isNotEmpty);
        expect(top.every((i) => MediaId.isBrowsePage(i.id)), isTrue);
        expect(top.every((i) => i.playable == false), isTrue);
        // A page row carries no track metadata that would make a head unit
        // treat it as a song.
        expect(top.every((i) => i.duration == null), isTrue);
        expect(top.every((i) => i.artist == null), isTrue);
      });

      test('selecting a page row starts no playback', () async {
        final controller = FakePlaybackController();
        final handler = LinthraAudioHandler(
          controller,
          MediaBrowserTree(
              FakeMusicLibraryRepository(tracks: catalog(4 * pageSize + 7))),
        );
        addTearDown(() async {
          await handler.dispose();
          await controller.dispose();
        });

        final page = (await handler.getChildren(MediaId.library)).first;
        await handler.playFromMediaId(page.id);
        await _settle();

        expect(controller.playedTracks, isEmpty);
        expect(controller.state.currentTrack, isNull);
      });

      test('selecting a paged song plays the whole catalog at its index',
          () async {
        final tracks = catalog(4 * pageSize + 7);
        final controller = FakePlaybackController();
        final handler = LinthraAudioHandler(
          controller,
          MediaBrowserTree(FakeMusicLibraryRepository(tracks: tracks)),
        );
        addTearDown(() async {
          await handler.dispose();
          await controller.dispose();
        });

        // The first row of the *third* page — a song that the old flat list
        // would have buried past the Binder limit.
        final pages = await handler.getChildren(MediaId.library);
        final third = await handler.getChildren(pages[2].id);
        await handler.playFromMediaId(third.first.id);
        await _settle();

        // The whole catalog became the queue, positioned on the selected song —
        // exactly as an unpaged Songs selection always did.
        final PlaybackState state = controller.state;
        expect(controller.playedTracks, <Track>[tracks[2 * pageSize]]);
        expect(state.currentTrack!.uri, tracks[2 * pageSize].uri);
        expect(state.previous, hasLength(2 * pageSize));
        expect(state.previous.length + 1 + state.upNext.length, tracks.length);
      });

      test('paged browse output stays token-, path- and scheme-free', () async {
        final handler = handlerFor(catalog(pageSize + 5));

        for (final audio.MediaItem item in <audio.MediaItem>[
          ...await handler.getChildren(MediaId.library),
          ...await leaves(handler, MediaId.library),
        ]) {
          for (final String text in <String>[
            item.id,
            item.title,
            item.displaySubtitle ?? '',
            item.artist ?? '',
            item.album ?? '',
          ]) {
            expect(text, isNot(contains('api_key')));
            expect(text.toLowerCase(), isNot(contains('secret')));
            expect(text, isNot(contains('jellyfin:')));
            expect(text, isNot(contains('://')));
          }
          expect(item.extras, anyOf(isNull, isEmpty));
        }
      });

      test('repeated browse requests are byte-identical (no rebuild loop)',
          () async {
        final handler = handlerFor(catalog(4 * pageSize + 7));

        List<String> shapeOf(List<audio.MediaItem> items) => <String>[
              for (final i in items) '${i.id}|${i.title}|${i.playable}',
            ];

        final first = shapeOf(await handler.getChildren(MediaId.library));
        final second = shapeOf(await handler.getChildren(MediaId.library));
        final third = shapeOf(await handler.getChildren(MediaId.library));

        expect(second, first);
        expect(third, first);
      });

      test('a small library is untouched — still one flat Songs list',
          () async {
        final handler = handlerFor(_library);

        final items = await handler.getChildren(MediaId.library);

        expect(items.map((i) => i.id), [
          MediaId.libraryTrack('/a.mp3'),
          MediaId.libraryTrack('/b.mp3'),
          MediaId.libraryTrack('/c.mp3'),
        ]);
        expect(items.every((i) => i.playable == true), isTrue);
      });
    });

    // Follow-up coverage for #539 review point 1: the browse options Android
    // Auto sends are honoured here, because nothing below this handler applies
    // them. MediaBrowserServiceCompat runs its own applyOptions only under
    // RESULT_FLAG_OPTION_NOT_HANDLED, which the base class sets only when the
    // service leaves onLoadChildren(parentId, result, options) unoverridden —
    // and audio_service's AudioService overrides it, calling
    // result.sendResult(...) directly. So an unhandled page request would hand
    // the client page 0 over and over.
    group('browse page options are honoured (#539)', () {
      const String extraPage = MediaBrowseOptions.extraPage;
      const String extraPageSize = MediaBrowseOptions.extraPageSize;

      List<Track> catalog(int n) => <Track>[
            for (int i = 0; i < n; i++)
              Track(
                id: 'jellyfin:$i',
                title: 'Song ${i.toString().padLeft(5, '0')}',
                uri: 'jellyfin:https://host.example/Items/$i?api_key=SECRET',
              ),
          ];

      LinthraAudioHandler handlerFor(List<Track> tracks) {
        final controller = FakePlaybackController();
        final handler = LinthraAudioHandler(
          controller,
          MediaBrowserTree(FakeMusicLibraryRepository(tracks: tracks)),
        );
        addTearDown(() async {
          await handler.dispose();
          await controller.dispose();
        });
        return handler;
      }

      test('page 0 and a non-zero page return different, adjacent windows',
          () async {
        // 200 songs: one flat, unpaged node, browsed 50 at a time.
        final handler = handlerFor(catalog(200));

        final unpaged = await handler.getChildren(MediaId.library);
        final page0 = await handler.getChildren(MediaId.library,
            <String, dynamic>{extraPage: 0, extraPageSize: 50});
        final page1 = await handler.getChildren(MediaId.library,
            <String, dynamic>{extraPage: 1, extraPageSize: 50});
        final page3 = await handler.getChildren(MediaId.library,
            <String, dynamic>{extraPage: 3, extraPageSize: 50});

        expect(unpaged, hasLength(200));
        expect(page0, hasLength(50));
        expect(page1, hasLength(50));
        expect(page3, hasLength(50));
        // The regression this guards: page 1 must not repeat page 0.
        expect(page1.map((i) => i.id), isNot(page0.map((i) => i.id)));
        expect(page0.map((i) => i.id), unpaged.take(50).map((i) => i.id));
        expect(
            page1.map((i) => i.id), unpaged.skip(50).take(50).map((i) => i.id));
        expect(page3.map((i) => i.id),
            unpaged.skip(150).take(50).map((i) => i.id));
      });

      test('paging tiles a node exactly, with no gap, overlap or loss',
          () async {
        final handler = handlerFor(catalog(200));

        final seen = <String>[];
        for (int page = 0;; page++) {
          final items = await handler.getChildren(MediaId.library,
              <String, dynamic>{extraPage: page, extraPageSize: 30});
          if (items.isEmpty) break;
          seen.addAll(items.map((i) => i.id));
          expect(page, lessThan(20), reason: 'paging did not terminate');
        }

        final all = await handler.getChildren(MediaId.library);
        expect(seen, all.map((i) => i.id).toList());
        expect(seen.toSet(), hasLength(200));
      });

      test('a partial last page, then an empty one, ends the walk', () async {
        // 200 songs at 60 per page: 3 full pages, a 20-row remainder, then end.
        final handler = handlerFor(catalog(200));

        Future<int> sizeOf(int page) async => (await handler.getChildren(
              MediaId.library,
              <String, dynamic>{extraPage: page, extraPageSize: 60},
            ))
                .length;

        expect(await sizeOf(2), 60);
        expect(await sizeOf(3), 20);
        expect(await sizeOf(4), 0);
      });

      test('paging composes with the tree bound on a large catalog', () async {
        // 4 pages' worth of page containers, browsed 2 rows at a time.
        final handler =
            handlerFor(catalog(4 * MediaBrowserTree.browsePageSize));

        final containers = await handler.getChildren(MediaId.library);
        expect(containers, hasLength(4));
        expect(containers.every((i) => MediaId.isBrowsePage(i.id)), isTrue);

        final second = await handler.getChildren(
            MediaId.library, <String, dynamic>{extraPage: 1, extraPageSize: 2});
        expect(second.map((i) => i.id),
            containers.skip(2).take(2).map((i) => i.id));

        // And a page *inside* a container still pages correctly.
        final inside = await handler.getChildren(containers.first.id,
            <String, dynamic>{extraPage: 1, extraPageSize: 50});
        final whole = await handler.getChildren(containers.first.id);
        expect(
            inside.map((i) => i.id), whole.skip(50).take(50).map((i) => i.id));
      });

      test('absent, empty or nonsensical options return the whole node',
          () async {
        final handler = handlerFor(catalog(10));

        // No options at all: Android's two-argument onLoadChildren path.
        expect(await handler.getChildren(MediaId.library), hasLength(10));
        expect(await handler.getChildren(MediaId.library, <String, dynamic>{}),
            hasLength(10));
        // Only one half of the window specified, or a junk type: treated
        // exactly as MediaBrowserServiceCompat.applyOptions would.
        expect(
          await handler.getChildren(
              MediaId.library, <String, dynamic>{extraPage: 'nope'}),
          hasLength(10),
        );
        expect(
          await handler.getChildren(MediaId.library,
              <String, dynamic>{extraPage: -1, extraPageSize: -1}),
          hasLength(10),
        );
        // A negative page, a zero page size, and a page past the end are all
        // empty — how a client learns it has run out.
        expect(
          await handler.getChildren(MediaId.library,
              <String, dynamic>{extraPage: -2, extraPageSize: 5}),
          isEmpty,
        );
        expect(
          await handler.getChildren(MediaId.library,
              <String, dynamic>{extraPage: 0, extraPageSize: 0}),
          isEmpty,
        );
        expect(
          await handler.getChildren(MediaId.library,
              <String, dynamic>{extraPage: 99, extraPageSize: 5}),
          isEmpty,
        );
      });

      test('paged rows stay token-, path- and scheme-free', () async {
        final handler = handlerFor(catalog(200));

        final items = await handler.getChildren(MediaId.library,
            <String, dynamic>{extraPage: 2, extraPageSize: 50});

        expect(items, isNotEmpty);
        for (final item in items) {
          for (final String text in <String>[
            item.id,
            item.title,
            item.displaySubtitle ?? '',
          ]) {
            expect(text, isNot(contains('api_key')));
            expect(text.toLowerCase(), isNot(contains('secret')));
            expect(text, isNot(contains('://')));
          }
        }
      });
    });

    // Follow-up coverage for #539 review point 2: fixing the browse response
    // must not move the oversized-payload problem onto the playback path.
    // Selecting a song still hands the controller the whole catalog, and
    // `queue.add(...)` becomes a native MediaSessionCompat queue delivered in
    // one Binder transaction — so the *published* queue is a bounded window,
    // while the controller keeps the full queue.
    group('the published media-session queue stays bounded (#539)', () {
      const int maxQueue = LinthraAudioHandler.maxPublishedQueueItems;
      const int history = LinthraAudioHandler.publishedQueueHistory;

      // 10k+, well past the ~1.5k Binder threshold, but cheap to build.
      const int bigCatalog = 12000;

      List<Track> catalog(int n) => <Track>[
            for (int i = 0; i < n; i++)
              Track(
                id: 'jellyfin:$i',
                title: 'Song ${i.toString().padLeft(5, '0')}',
                uri: 'jellyfin:https://host.example/Items/$i?api_key=SECRET',
                artistName: 'Artist ${i % 40}',
                albumName: 'Album ${i % 90}',
              ),
          ];

      /// A handler plus its controller, torn down with the test.
      (LinthraAudioHandler, FakePlaybackController) rig(List<Track> tracks) {
        final controller = FakePlaybackController();
        final handler = LinthraAudioHandler(
          controller,
          MediaBrowserTree(FakeMusicLibraryRepository(tracks: tracks)),
        );
        addTearDown(() async {
          await handler.dispose();
          await controller.dispose();
        });
        return (handler, controller);
      }

      /// The Songs leaf id for [track] — position-independent, so it is the
      /// same id whichever page of the browse tree listed it.
      String leafIdFor(Track track) => MediaId.libraryTrack(track.uri);

      test('selecting a song from a 12k library publishes a bounded queue',
          () async {
        final tracks = catalog(bigCatalog);
        final (handler, controller) = rig(tracks);

        await handler.playFromMediaId(leafIdFor(tracks[0]));
        await _settle();

        // The controller really does own the whole catalog...
        expect(controller.state.upNext.length + 1, tracks.length);
        // ...but the session only ever sees a window of it.
        expect(handler.queue.value, hasLength(maxQueue));
        expect(handler.queue.value.length, lessThan(tracks.length));
      });

      test('the window follows playback and always holds the current track',
          () async {
        final tracks = catalog(bigCatalog);
        final (handler, controller) = rig(tracks);

        Future<void> selectAndCheck(int index) async {
          await handler.playFromMediaId(leafIdFor(tracks[index]));
          await _settle();

          final published = handler.queue.value;
          expect(published, hasLength(maxQueue), reason: 'at $index');
          final int active = handler.playbackState.value.queueIndex!;
          expect(active, inInclusiveRange(0, published.length - 1),
              reason: 'at $index');
          // The highlighted row is the track that is actually playing.
          expect(published[active].title, tracks[index].title,
              reason: 'at $index');
          expect(controller.state.currentTrack!.uri, tracks[index].uri,
              reason: 'at $index');
        }

        await selectAndCheck(0); // first
        await selectAndCheck(bigCatalog ~/ 2); // middle
        await selectAndCheck(bigCatalog - 1); // last
      });

      test('first, middle and last selections keep the window in range',
          () async {
        final tracks = catalog(bigCatalog);
        final (handler, _) = rig(tracks);

        // First track: nothing behind it, so the window starts at 0.
        await handler.playFromMediaId(leafIdFor(tracks.first));
        await _settle();
        expect(handler.playbackState.value.queueIndex, 0);
        expect(handler.queue.value.first.title, tracks.first.title);

        // Middle: the configured amount of history sits behind the current row.
        await handler.playFromMediaId(leafIdFor(tracks[5000]));
        await _settle();
        expect(handler.playbackState.value.queueIndex, history);

        // Last track: the window slides back so it is still full, and the
        // current row is its final entry.
        await handler.playFromMediaId(leafIdFor(tracks.last));
        await _settle();
        expect(handler.queue.value, hasLength(maxQueue));
        expect(handler.playbackState.value.queueIndex, maxQueue - 1);
        expect(handler.queue.value.last.title, tracks.last.title);
      });

      test('a small library publishes its whole queue, unchanged', () async {
        final (handler, _) = rig(_library);

        await handler.playFromMediaId(MediaId.libraryTrack('/a.mp3'));
        await _settle();

        expect(handler.queue.value.map((i) => i.title),
            _library.map((t) => t.title));
        expect(handler.playbackState.value.queueIndex, 0);
      });

      test('next and previous cross the window boundary correctly', () async {
        final tracks = catalog(bigCatalog);
        final (handler, controller) = rig(tracks);

        // Start where the window is full and sliding: current at `history`.
        await handler.playFromMediaId(leafIdFor(tracks[1000]));
        await _settle();
        expect(handler.playbackState.value.queueIndex, history);

        // Walk forward past where the window must slide, and check the session
        // keeps naming the right track at the right row every step.
        for (int step = 1; step <= 3; step++) {
          await handler.skipToNext();
          await _settle();
          final published = handler.queue.value;
          final int active = handler.playbackState.value.queueIndex!;
          expect(controller.state.currentTrack!.uri, tracks[1000 + step].uri);
          expect(published[active].title, tracks[1000 + step].title);
          expect(published, hasLength(maxQueue));
        }

        // And back again.
        for (int step = 2; step >= 0; step--) {
          await handler.skipToPrevious();
          await _settle();
          final published = handler.queue.value;
          final int active = handler.playbackState.value.queueIndex!;
          expect(controller.state.currentTrack!.uri, tracks[1000 + step].uri);
          expect(published[active].title, tracks[1000 + step].title);
        }
      });

      test('skipToQueueItem maps a windowed row to the right track', () async {
        final tracks = catalog(bigCatalog);
        final (handler, controller) = rig(tracks);

        await handler.playFromMediaId(leafIdFor(tracks[5000]));
        await _settle();

        // Row 0 of the published window is `history` tracks behind the current
        // one — the offset that a naive index-as-absolute mapping would get
        // wrong.
        await handler.skipToQueueItem(0);
        await _settle();
        expect(controller.state.currentTrack!.uri, tracks[5000 - history].uri);

        // A forward row within the same window.
        await handler.playFromMediaId(leafIdFor(tracks[5000]));
        await _settle();
        await handler.skipToQueueItem(history + 10);
        await _settle();
        expect(controller.state.currentTrack!.uri, tracks[5010].uri);

        // The published row for the current track is a no-op, not a restart.
        await handler.playFromMediaId(leafIdFor(tracks[5000]));
        await _settle();
        final int playsBefore = controller.playedTracks.length;
        await handler.skipToQueueItem(handler.playbackState.value.queueIndex!);
        await _settle();
        expect(controller.playedTracks, hasLength(playsBefore));
        expect(controller.state.currentTrack!.uri, tracks[5000].uri);
      });

      test('every published row maps back to the track it displays', () async {
        final tracks = catalog(bigCatalog);
        final (handler, controller) = rig(tracks);

        await handler.playFromMediaId(leafIdFor(tracks[5000]));
        await _settle();
        final published = handler.queue.value;

        // Spot-check across the whole window, including both ends.
        for (final int row in <int>[
          0,
          1,
          history - 1,
          history + 1,
          published.length ~/ 2,
          published.length - 1
        ]) {
          await handler.playFromMediaId(leafIdFor(tracks[5000]));
          await _settle();
          final String expectedTitle = handler.queue.value[row].title;
          await handler.skipToQueueItem(row);
          await _settle();
          expect(controller.state.currentTrack!.title, expectedTitle,
              reason: 'row $row');
        }
      });

      test('an out-of-window row is a safe no-op, never a wrong track',
          () async {
        final tracks = catalog(bigCatalog);
        final (handler, controller) = rig(tracks);

        await handler.playFromMediaId(leafIdFor(tracks.last));
        await _settle();
        final int playsBefore = controller.playedTracks.length;

        // Rows that do not exist in the published window.
        await handler.skipToQueueItem(-1);
        await handler.skipToQueueItem(maxQueue + 5);
        await handler.skipToQueueItem(bigCatalog + 100);
        await _settle();

        expect(controller.playedTracks, hasLength(playsBefore));
        expect(controller.state.currentTrack!.uri, tracks.last.uri);
      });

      test('selecting a song starts it exactly once — no duplicate playback',
          () async {
        final tracks = catalog(bigCatalog);
        final (handler, controller) = rig(tracks);

        await handler.playFromMediaId(leafIdFor(tracks[7000]));
        await _settle();

        expect(controller.playedTracks, <Track>[tracks[7000]]);
        expect(controller.state.currentTrack!.uri, tracks[7000].uri);
      });

      test('published queue rows carry no token, path or scheme', () async {
        final tracks = catalog(bigCatalog);
        final (handler, _) = rig(tracks);

        await handler.playFromMediaId(leafIdFor(tracks[5000]));
        await _settle();

        for (final item in handler.queue.value) {
          for (final String text in <String>[
            item.id,
            item.title,
            item.artist ?? '',
            item.album ?? '',
          ]) {
            expect(text, isNot(contains('api_key')));
            expect(text.toLowerCase(), isNot(contains('secret')));
            expect(text, isNot(contains('://')));
          }
          expect(item.extras, anyOf(isNull, isEmpty));
        }
      });
    });

    group('offline & favorites browsing', () {
      late FakePlaybackController offController;
      late LinthraAudioHandler offHandler;

      setUp(() {
        offController = FakePlaybackController();
        offHandler = LinthraAudioHandler(
          offController,
          MediaBrowserTree(
            FakeMusicLibraryRepository(tracks: _library),
            favorites: FakeFavoritesRepository({'a'}),
            downloads: FakeDownloadRepository(<String>{
              CachedTrack.cacheKeyForTrack(_track('b')),
              CachedTrack.cacheKeyForTrack(_track('c')),
            }),
          ),
        );
      });

      tearDown(() async {
        await offHandler.dispose();
        await offController.dispose();
      });

      test('root surfaces Favorites and Offline when the user has some',
          () async {
        final ids =
            (await offHandler.getChildren(MediaId.root)).map((i) => i.id);
        expect(
            ids,
            containsAllInOrder(<String>[
              MediaId.favorites,
              MediaId.offline,
            ]));
      });

      test('offline lists the downloaded tracks; selecting one plays it',
          () async {
        final offline = await offHandler.getChildren(MediaId.offline);
        expect(offline.map((i) => i.title), ['Song b', 'Song c']);
        expect(offline.every((i) => i.playable == true), isTrue);

        await offHandler.playFromMediaId(offline.first.id);
        await _settle();
        expect(offController.state.currentTrack?.id, 'b');
        // The offline section seeds the queue with the offline list.
        expect(offController.state.upNext.map((t) => t.id), ['c']);
      });
    });

    group('media-session queue (car / head-unit Up Next)', () {
      test('publishes the queue as history + current + up-next, in order',
          () async {
        // Start at the middle track so there is both history and up-next.
        await controller.playTracks(_library, startIndex: 1);
        await _settle();

        // history (a), current (b), up-next (c) — the flat order a head unit's
        // Up Next list shows and skipToQueueItem indexes into.
        expect(handler.queue.value.map((i) => i.id), ['a', 'b', 'c']);
        // The now-playing item shares its id with its queue row, so the car
        // highlights the right row.
        expect(handler.mediaItem.value?.id, 'b');
      });

      test('republishes the queue on an edit, not on a position tick',
          () async {
        await controller.playTracks(<Track>[_track('a'), _track('b')]);
        await _settle();

        final List<List<audio.MediaItem>> pushes = <List<audio.MediaItem>>[];
        final sub = handler.queue.listen(pushes.add);
        addTearDown(sub.cancel);
        await _settle();
        // Listening replays the current value; count only pushes after that.
        final int baseline = pushes.length;

        // Position ticks don't change the queue contents → no new push.
        for (int ms = 200; ms <= 800; ms += 200) {
          controller.emit(
            controller.state.copyWith(position: Duration(milliseconds: ms)),
          );
          await _settle();
        }
        expect(pushes.length, baseline);

        // Adding a track grows up-next → exactly the queue is re-published.
        controller.addToQueue(_track('c'));
        await _settle();
        expect(pushes.length, greaterThan(baseline));
        expect(pushes.last.map((i) => i.id), ['a', 'b', 'c']);
      });

      test('skipToQueueItem jumps forward to an up-next row', () async {
        await controller.playTracks(_library); // a current, [b, c] up-next
        await _settle();

        // queue = [a, b, c]; row 2 is up-next 'c'.
        await handler.skipToQueueItem(2);
        await _settle();

        expect(controller.state.currentTrack?.id, 'c');
        expect(handler.mediaItem.value?.id, 'c');
      });

      test('skipToQueueItem steps back to a history row', () async {
        await controller.playTracks(_library);
        await controller.skipToNext();
        await controller.skipToNext(); // current c, history [a, b]
        await _settle();

        // queue = [a, b, c]; row 0 is history 'a'.
        await handler.skipToQueueItem(0);
        await _settle();

        expect(controller.state.currentTrack?.id, 'a');
        expect(handler.mediaItem.value?.id, 'a');
      });

      test('skipToQueueItem on the current row leaves it playing', () async {
        await controller.playTracks(_library);
        await controller.skipToNext(); // current b, history [a]
        await _settle();
        final int playedBefore = controller.playedTracks.length;

        await handler.skipToQueueItem(1); // row 1 == current

        await _settle();
        expect(controller.state.currentTrack?.id, 'b');
        expect(controller.playedTracks.length, playedBefore);
      });

      test('skipToQueueItem out of range is a safe no-op', () async {
        await controller.playTracks(_library);
        await _settle();
        final int playedBefore = controller.playedTracks.length;

        await handler.skipToQueueItem(99);
        await handler.skipToQueueItem(-1);
        await _settle();

        expect(controller.state.currentTrack?.id, 'a');
        expect(controller.playedTracks.length, playedBefore);
      });
    });

    group('car skip keeps the queue & metadata correct', () {
      test('skipToNext updates the current media item', () async {
        await controller.playTracks(_library);
        await _settle();
        expect(handler.mediaItem.value?.id, 'a');

        await handler.skipToNext();
        await _settle();

        expect(handler.mediaItem.value?.id, 'b');
        expect(handler.mediaItem.value?.title, 'Song b');
        expect(handler.mediaItem.value?.artist, 'Artist b');
      });

      test('skipToPrevious updates the current media item', () async {
        await controller.playTracks(_library, startIndex: 1);
        await _settle();
        expect(handler.mediaItem.value?.id, 'b');

        await handler.skipToPrevious();
        await _settle();

        expect(handler.mediaItem.value?.id, 'a');
      });

      test('a queue selected from the car supports next & previous', () async {
        // Selecting a library track in the car builds the queue (the rest of
        // the library becomes up-next), then car skip moves within that queue.
        await handler.playFromMediaId(MediaId.libraryTrack('/a.mp3'));
        await _settle();
        expect(handler.mediaItem.value?.id, 'a');

        await handler.skipToNext();
        await _settle();
        expect(controller.state.currentTrack?.id, 'b');
        expect(handler.mediaItem.value?.id, 'b');

        await handler.skipToPrevious();
        await _settle();
        expect(controller.state.currentTrack?.id, 'a');
      });

      test('car Next at the end and Previous at the start are safe no-ops',
          () async {
        await controller.playTracks(<Track>[_track('a')]); // single track
        await _settle();

        await handler.skipToNext();
        await handler.skipToPrevious();
        await _settle();

        expect(controller.state.currentTrack?.id, 'a');
        expect(controller.skipCount, 1);
        expect(controller.previousCount, 1);
      });
    });

    group('shuffle & repeat', () {
      test('forwards setShuffleMode to the controller', () async {
        await handler.setShuffleMode(audio.AudioServiceShuffleMode.all);
        expect(controller.state.shuffleEnabled, isTrue);

        await handler.setShuffleMode(audio.AudioServiceShuffleMode.none);
        expect(controller.state.shuffleEnabled, isFalse);
      });

      test('forwards setRepeatMode to the controller', () async {
        await handler.setRepeatMode(audio.AudioServiceRepeatMode.all);
        expect(controller.state.repeatMode, RepeatMode.all);

        await handler.setRepeatMode(audio.AudioServiceRepeatMode.one);
        expect(controller.state.repeatMode, RepeatMode.one);

        await handler.setRepeatMode(audio.AudioServiceRepeatMode.none);
        expect(controller.state.repeatMode, RepeatMode.off);
      });

      test('mirrors the controller shuffle/repeat into the session', () async {
        await controller.playTracks([_track('a'), _track('b')]);
        controller.setShuffleEnabled(true);
        controller.setRepeatMode(RepeatMode.one);
        await _settle();

        final state = handler.playbackState.value;
        expect(state.shuffleMode, audio.AudioServiceShuffleMode.all);
        expect(state.repeatMode, audio.AudioServiceRepeatMode.one);
        expect(
          state.systemActions,
          containsAll(<audio.MediaAction>{
            audio.MediaAction.setShuffleMode,
            audio.MediaAction.setRepeatMode,
          }),
        );
      });
    });

    group('Bluetooth / car media-session surface', () {
      // A Bluetooth headset, a car head unit, and the lock screen all drive the
      // same MediaSession. These lock in the device-facing invariants the audit
      // verified (see docs/audio-bluetooth-cpu-audit.md): a stable capability
      // set, artwork in the now-playing item when the track has it, and a Stop
      // control that is always offered.

      test('advertises the full transport capability set even on one track',
          () async {
        // A single-track queue has no next/previous, so the *visible* controls
        // omit skip (asserted above) — but the session must still advertise the
        // skip capabilities steadily, so a head unit / Bluetooth device that
        // cached them at connect time keeps its Next / Previous and queue-row
        // buttons live regardless of position in the queue.
        await controller.playTracks(<Track>[_track('a')]);
        await _settle();

        expect(
          handler.playbackState.value.systemActions,
          containsAll(<audio.MediaAction>{
            audio.MediaAction.seek,
            audio.MediaAction.skipToNext,
            audio.MediaAction.skipToPrevious,
            audio.MediaAction.skipToQueueItem,
          }),
        );
      });

      test('mirrors artwork into the now-playing item when the track has it',
          () async {
        final withArt = Track(
          id: 'art',
          title: 'Song art',
          uri: '/art.mp3',
          artistName: 'Artist art',
          albumName: 'Album art',
          artworkUri: Uri.parse('https://music.example.com/art/primary'),
        );
        await controller.playTracks(<Track>[withArt]);
        await _settle();

        expect(
          handler.mediaItem.value?.artUri,
          Uri.parse('https://music.example.com/art/primary'),
        );
      });

      test('omits artwork when the track has none ("when available")',
          () async {
        // _track('a') carries no artworkUri.
        await controller.playTracks(<Track>[_track('a')]);
        await _settle();

        expect(handler.mediaItem.value, isNotNull);
        expect(handler.mediaItem.value?.artUri, isNull);
      });

      test('always offers the Stop control, playing and paused', () async {
        await controller.playTracks(<Track>[_track('a')]);
        await _settle();
        expect(
          handler.playbackState.value.controls,
          contains(audio.MediaControl.stop),
        );

        controller.emit(
          controller.state.copyWith(status: PlaybackStatus.paused),
        );
        await _settle();
        expect(
          handler.playbackState.value.controls,
          contains(audio.MediaControl.stop),
        );
      });
    });

    group('safe media items', () {
      final jellyfin = Track(
        id: 'jf-guid-123',
        title: 'Remote Song',
        uri: 'jellyfin:jf-guid-123',
        artistName: 'Remote Artist',
        albumName: 'Remote Album',
        artworkUri: Uri.parse(
          'https://music.example.com/Items/jf-guid-123/Images/Primary',
        ),
      );
      const local = Track(
        id: 'local-1',
        title: 'Local Song',
        uri: '/storage/music/local.mp3',
      );

      test('library items carry token-free ids, no extras, token-free art',
          () async {
        final libController = FakePlaybackController();
        final libHandler = LinthraAudioHandler(
          libController,
          MediaBrowserTree(
            FakeMusicLibraryRepository(tracks: <Track>[jellyfin, local]),
          ),
        );
        addTearDown(() async {
          await libHandler.dispose();
          await libController.dispose();
        });

        final items = await libHandler.getChildren(MediaId.library);

        // Keyed by a hash of the uri; pass the same uris libraryTrack() hashes.
        expect(items.map((i) => i.id), [
          MediaId.libraryTrack('jellyfin:jf-guid-123'),
          MediaId.libraryTrack('/storage/music/local.mp3'),
        ]);
        for (final item in items) {
          // Ids never carry a token, an auth query, a URI scheme, or a stream
          // URL — only the opaque catalog id.
          expect(item.id, isNot(contains('api_key')));
          expect(item.id, isNot(contains('token')));
          expect(item.id, isNot(contains('jellyfin:')));
          expect(item.id, isNot(contains('://')));
          // We attach no extras, so nothing can leak through them.
          expect(item.extras, isNull);
          // The artwork URL (when present) is the token-free image endpoint.
          final String art = item.artUri?.toString() ?? '';
          expect(art, isNot(contains('api_key')));
          expect(art.toLowerCase(), isNot(contains('token')));
        }
      });

      test('now-playing item and queue rows are token-free, with no extras',
          () async {
        // The same secret-free guarantee must hold for what the car shows while
        // playing — the now-playing media item and every published queue row —
        // not just the browse tree.
        final playController = FakePlaybackController();
        final playHandler = LinthraAudioHandler(
          playController,
          MediaBrowserTree(
            FakeMusicLibraryRepository(tracks: <Track>[jellyfin, local]),
          ),
        );
        addTearDown(() async {
          await playHandler.dispose();
          await playController.dispose();
        });

        await playController.playTracks(<Track>[jellyfin, local]);
        await _settle();

        final nowPlaying = playHandler.mediaItem.value;
        expect(nowPlaying, isNotNull);
        // The id is the opaque catalog id, never the `jellyfin:` uri.
        expect(nowPlaying!.id, 'jf-guid-123');

        final queueRows = playHandler.queue.value;
        expect(queueRows.map((i) => i.id), ['jf-guid-123', 'local-1']);

        for (final item in <audio.MediaItem>[nowPlaying, ...queueRows]) {
          expect(item.id, isNot(contains('api_key')));
          expect(item.id.toLowerCase(), isNot(contains('token')));
          expect(item.id, isNot(contains('jellyfin:')));
          expect(item.id, isNot(contains('://')));
          expect(item.extras, isNull);
          final String art = item.artUri?.toString() ?? '';
          expect(art, isNot(contains('api_key')));
          expect(art.toLowerCase(), isNot(contains('token')));
        }
      });

      test('album containers carry token-free art and no extras', () async {
        final albController = FakePlaybackController();
        final albHandler = LinthraAudioHandler(
          albController,
          MediaBrowserTree(
            FakeMusicLibraryRepository(tracks: <Track>[jellyfin, local]),
          ),
        );
        addTearDown(() async {
          await albHandler.dispose();
          await albController.dispose();
        });

        final albums = await albHandler.getChildren(MediaId.albums);
        expect(albums, isNotEmpty);
        for (final item in albums) {
          // Browsable container: not playable, but may carry the album's
          // token-free cover art for the car row.
          expect(item.playable, isFalse);
          expect(item.extras, isNull);
          expect(item.id, isNot(contains('jellyfin:')));
          expect(item.id, isNot(contains('://')));
          final String art = item.artUri?.toString() ?? '';
          expect(art, isNot(contains('api_key')));
          expect(art.toLowerCase(), isNot(contains('token')));
        }
      });
    });

    group('Subsonic media-session artwork (privacy-safe local cache)', () {
      // A Subsonic track persists a *credential-free* reference in artworkUri
      // (subsonic-cover:<id>). The platform media session loads artUri itself —
      // somewhere Linthra can't add the salt+token — so the handler attaches a
      // *pre-warmed local* cover (a file: the MediaArtworkPrewarmService cached
      // ahead of time), never the reference and never the getCoverArt URL. The
      // read is synchronous, so a warmed cover is present on the very first push
      // (beating a head unit's metadata snapshot) and nothing fetches on the
      // playback path.
      final subsonic = Track(
        id: 'sub-1',
        title: 'Sub Song',
        uri: 'subsonic:sub-1',
        artistName: 'Sub Artist',
        albumName: 'Sub Album',
        artworkUri: Uri.parse('subsonic-cover:al-9'),
      );
      final reference = Uri.parse('subsonic-cover:al-9');
      // What the cache hands back: a credential-free FileProvider content:// URI
      // over the cached cover, which the platform session can read.
      final localArt = Uri.parse(
        'content://io.github.thezupzup.linthra.mediaartwork/media_artwork/'
        'abc.img',
      );

      LinthraAudioHandler handlerWith(
        FakePlaybackController c,
        List<Track> tracks, {
        MediaArtworkSource? artwork,
      }) {
        final h = LinthraAudioHandler(
          c,
          MediaBrowserTree(FakeMusicLibraryRepository(tracks: tracks)),
          artwork: artwork,
        );
        addTearDown(() async {
          await h.dispose();
          await c.dispose();
          if (artwork is _RecordingArtworkSource) await artwork.close();
        });
        return h;
      }

      test(
          'shows a pre-warmed cover as a safe local file artUri on the first '
          'push', () async {
        final source = _RecordingArtworkSource(<Uri, Uri>{reference: localArt});
        final c = FakePlaybackController();
        final h = handlerWith(c, <Track>[subsonic], artwork: source);

        await c.playTracks(<Track>[subsonic]);
        await _settle(); // a single broadcast — the read is synchronous

        // The now-playing item — what the lock screen / Android Auto card shows
        // — carries the safe local cover, present immediately (snapshot-safe).
        expect(h.mediaItem.value?.id, 'sub-1');
        expect(h.mediaItem.value?.artUri, localArt);
        // It was looked up by the credential-free reference, nothing else.
        expect(source.queries, contains(reference));
      });

      test(
          'the now-playing artUri is a safe file:, never the reference or a '
          'credential', () async {
        final source = _RecordingArtworkSource(<Uri, Uri>{reference: localArt});
        final c = FakePlaybackController();
        final h = handlerWith(c, <Track>[subsonic], artwork: source);

        await c.playTracks(<Track>[subsonic]);
        await _settle();

        final String art = h.mediaItem.value?.artUri?.toString() ?? '';
        expect(art, startsWith('content:'));
        expect(art, isNot(contains('subsonic-cover')));
        expect(art.toLowerCase(), isNot(contains('getcoverart')));
        expect(art.toLowerCase(), isNot(contains('token')));
        expect(art.toLowerCase(), isNot(contains('u=')));
        expect(art.toLowerCase(), isNot(contains('t=')));
        expect(art.toLowerCase(), isNot(contains('s=')));
      });

      test('an un-warmed cover leaves artUri null without affecting playback',
          () async {
        // The cover isn't cached yet (or couldn't be): artUri is null, never the
        // reference, and the rest of the now-playing metadata is intact.
        final source = _RecordingArtworkSource(); // empty cache
        final c = FakePlaybackController();
        final h = handlerWith(c, <Track>[subsonic], artwork: source);

        await c.playTracks(<Track>[subsonic]);
        await _settle();

        final item = h.mediaItem.value;
        expect(item, isNotNull);
        expect(item!.id, 'sub-1'); // metadata intact, playback unaffected
        expect(item.title, 'Sub Song');
        expect(item.artUri, isNull); // no artwork, and crucially no leak
      });

      test(
          'a cover warmed mid-track appears immediately via coverReady, no '
          'position tick needed', () async {
        // The cold first-track case: the cover finishes warming after the card
        // is published art-less. The coverReady event re-publishes the item at
        // once — no waiting for the next playback tick (the residual delay fix).
        final source = _RecordingArtworkSource(); // empty at first
        final c = FakePlaybackController();
        final h = handlerWith(c, <Track>[subsonic], artwork: source);

        await c.playTracks(<Track>[subsonic]);
        await _settle();
        expect(h.mediaItem.value?.artUri, isNull);

        // The prewarm completes out of band → cover cached + coverReady fires.
        // No position tick is emitted; the cover must still appear.
        source.warm(reference, localArt);
        await _settle();

        expect(h.mediaItem.value?.artUri, localArt);
      });

      test('coverReady for the current track re-publishes only once (no loop)',
          () async {
        // The re-publish must be a single, gated push: one item with art, never
        // a tight loop of re-broadcasts.
        final source = _RecordingArtworkSource();
        final c = FakePlaybackController();
        final h = handlerWith(c, <Track>[subsonic], artwork: source);

        final List<audio.MediaItem?> pushes = <audio.MediaItem?>[];
        final sub = h.mediaItem.listen(pushes.add);
        addTearDown(sub.cancel);

        await c.playTracks(<Track>[subsonic]);
        await _settle();
        final int beforeWarm = pushes.length;

        source.warm(reference, localArt); // cover cached + coverReady
        await _settle();

        // Exactly one extra push — the item that gained the art.
        expect(pushes.length, beforeWarm + 1);
        expect(pushes.last?.artUri, localArt);

        // A duplicate coverReady for an already-shown cover is a no-op (the
        // _sameItem guard), so no further push.
        source.warm(reference, localArt);
        await _settle();
        expect(pushes.length, beforeWarm + 1);
      });

      test('a cover warm / MediaItem rebroadcast never calls play', () async {
        // #172 artwork must stay strictly off the playback path: when a cover
        // finishes warming, the handler re-publishes the now-playing MediaItem
        // so the art appears — but it must NOT touch transport. A rebroadcast
        // that resumed/started playback would be the "cover art restarted my
        // music" bug.
        final source = _RecordingArtworkSource();
        final c = FakePlaybackController();
        final h = handlerWith(c, <Track>[subsonic], artwork: source);

        // The user paused; the now-playing item is published, art-less.
        await c.playTracks(<Track>[subsonic]);
        c.emit(c.state.copyWith(status: PlaybackStatus.paused));
        await _settle();
        final int playsBefore = c.playedTracks.length;
        final int playCountBefore = c.playCount;

        // The cover warms out of band → coverReady fires → the item is
        // re-broadcast with its art. No transport command may result.
        source.warm(reference, localArt);
        await _settle();

        // The art landed (the rebroadcast did its job) …
        expect(h.mediaItem.value?.artUri, localArt);
        // … but playback was never started/resumed by it, and stays paused.
        expect(c.playCount, playCountBefore);
        expect(c.playedTracks.length, playsBefore);
        expect(c.pauseCount, 0);
        expect(h.playbackState.value.playing, isFalse);
      });

      test(
          'coverReady for a non-current cover leaves the now-playing item alone',
          () async {
        // Warming an up-next cover must not disturb the current now-playing item.
        final source = _RecordingArtworkSource();
        final c = FakePlaybackController();
        final h = handlerWith(c, <Track>[subsonic], artwork: source);

        await c.playTracks(<Track>[subsonic]);
        await _settle();

        // A different reference (some up-next cover) becomes ready.
        source.warm(Uri.parse('subsonic-cover:other'),
            Uri.parse('content://x/media_artwork/other.img'));
        await _settle();

        // The now-playing item is unchanged (still art-less for sub-1).
        expect(h.mediaItem.value?.id, 'sub-1');
        expect(h.mediaItem.value?.artUri, isNull);
      });

      test('without an artwork source, a reference never leaks into artUri',
          () async {
        // The default (a platform without the cache): the unloadable
        // subsonic-cover: reference must be dropped, not handed to the session.
        final c = FakePlaybackController();
        final h = handlerWith(c, <Track>[subsonic]); // no artwork source

        await c.playTracks(<Track>[subsonic]);
        await _settle();

        final item = h.mediaItem.value;
        expect(item, isNotNull);
        expect(item!.artUri, isNull);
        expect(
            item.artUri?.toString() ?? '', isNot(contains('subsonic-cover')));
      });

      test('browse-tree containers drop an un-warmed cover reference',
          () async {
        // Browse covers aren't pre-warmed, so a Subsonic album/artist
        // container's reference is dropped (null), never leaked as an unloadable
        // URI.
        final source = _RecordingArtworkSource(); // nothing cached
        final c = FakePlaybackController();
        final h = handlerWith(c, <Track>[subsonic], artwork: source);

        final albums = await h.getChildren(MediaId.albums);
        expect(albums, isNotEmpty);
        for (final item in albums) {
          expect(item.artUri, isNull);
          expect(
            item.artUri?.toString() ?? '',
            isNot(contains('subsonic-cover')),
          );
        }
      });

      test('Jellyfin http art and local file art pass through unchanged',
          () async {
        // A platform-loadable cover (Jellyfin token-free http, a local file:) is
        // forwarded unchanged, and the artwork source is never even consulted.
        final jf = Track(
          id: 'jf',
          title: 'JF',
          uri: 'jellyfin:jf',
          artworkUri:
              Uri.parse('https://music.example.com/Items/jf/Images/Primary'),
        );
        final loc = Track(
          id: 'loc',
          title: 'Loc',
          uri: '/music/loc.mp3',
          artworkUri: Uri.parse('file:///cache/linthra_local_artwork/loc.img'),
        );
        final source = _RecordingArtworkSource();
        final c = FakePlaybackController();
        final h = handlerWith(c, <Track>[jf, loc], artwork: source);

        await c.playTracks(<Track>[jf, loc]);
        await _settle();

        // Jellyfin token-free http art is used as-is.
        final nowPlayingArt = h.mediaItem.value?.artUri;
        expect(
          nowPlayingArt,
          Uri.parse('https://music.example.com/Items/jf/Images/Primary'),
        );
        // The local file: art rides on its queue row unchanged.
        final locRow = h.queue.value.firstWhere((i) => i.id == 'loc');
        expect(
          locRow.artUri,
          Uri.parse('file:///cache/linthra_local_artwork/loc.img'),
        );
        // Neither becomes a content:// URI, so they are never served by the
        // media-artwork FileProvider and its read-grant logic never runs for
        // Jellyfin/local covers — only Subsonic references go through the cache.
        expect(nowPlayingArt?.isScheme('content'), isFalse);
        expect(locRow.artUri?.isScheme('content'), isFalse);
        // The cover source is not consulted at all for platform-loadable covers.
        expect(source.queries, isEmpty);
      });
    });
  });
}
