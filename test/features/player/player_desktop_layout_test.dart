import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/lyrics.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/lyrics_service.dart';
import 'package:linthra/features/player/lyrics_providers.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/player_screen.dart';
import 'package:linthra/features/player/widgets/album_artwork.dart';
import 'package:linthra/features/player/widgets/lyrics_view.dart';
import 'package:linthra/features/player/widgets/playback_controls.dart';
import 'package:linthra/features/player/widgets/track_metadata.dart';

import 'fake_playback_controller.dart';

class _FakeLyricsService implements LyricsService {
  _FakeLyricsService(this._lyrics);

  final Lyrics? _lyrics;

  @override
  Future<Lyrics?> lyricsFor(Track track) async => _lyrics;
}

const Track _track = Track(
  id: '1',
  title: 'Song One',
  uri: '/music/song1.mp3',
  artistName: 'Artist A',
  albumName: 'Album B',
);

const Lyrics _lyrics = Lyrics(
  lines: <LyricLine>[
    LyricLine(text: 'First line'),
    LyricLine(text: 'Second line'),
  ],
);

Future<void> _pumpPlayer(
  WidgetTester tester, {
  required Size size,
  Lyrics? lyrics,
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        playbackControllerProvider.overrideWithValue(
          FakePlaybackController(
            initial: const PlaybackState(
              status: PlaybackStatus.playing,
              currentTrack: _track,
            ),
          ),
        ),
        lyricsServiceProvider.overrideWithValue(_FakeLyricsService(lyrics)),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: textScaler),
            child: const PlayerScreen(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Rect _artworkRect(WidgetTester tester) =>
    tester.getRect(find.byType(AlbumArtwork).first);

Rect _controlsRect(WidgetTester tester) =>
    tester.getRect(find.byType(PlaybackControls));

void main() {
  group('Now Playing on a phone', () {
    testWidgets('stacks the cover above the controls', (tester) async {
      await _pumpPlayer(tester, size: const Size(390, 844));

      expect(
        _artworkRect(tester).bottom,
        lessThanOrEqualTo(_controlsRect(tester).top),
      );
      expect(find.byType(TrackMetadata), findsOneWidget);
    });

    testWidgets('lyrics take the cover’s place', (tester) async {
      await _pumpPlayer(
        tester,
        size: const Size(390, 844),
        lyrics: _lyrics,
      );

      await tester.tap(find.byTooltip('Lyrics'));
      await tester.pumpAndSettle();

      expect(find.byType(LyricsView), findsOneWidget);
      expect(find.byType(AlbumArtwork), findsNothing);
    });
  });

  group('Now Playing on a desktop window', () {
    testWidgets('puts the cover beside the metadata and transport',
        (tester) async {
      await _pumpPlayer(tester, size: const Size(1280, 800));

      final Rect artwork = _artworkRect(tester);
      final Rect controls = _controlsRect(tester);
      expect(artwork.right, lessThanOrEqualTo(controls.left));
      expect(artwork.width, closeTo(artwork.height, 1));
      expect(find.text('Song One'), findsOneWidget);
      expect(find.text('Artist A'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('lyrics open beside the cover instead of replacing it',
        (tester) async {
      await _pumpPlayer(
        tester,
        size: const Size(1280, 800),
        lyrics: _lyrics,
      );

      await tester.tap(find.byTooltip('Lyrics'));
      await tester.pumpAndSettle();

      expect(find.byType(LyricsView), findsOneWidget);
      expect(find.byType(AlbumArtwork), findsWidgets);
      expect(
        _artworkRect(tester).right,
        lessThanOrEqualTo(tester.getRect(find.byType(LyricsView)).left),
      );
      expect(find.byTooltip('Pause'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the smallest wide window shrinks the cover, not the transport',
        (tester) async {
      await _pumpPlayer(tester, size: const Size(1280, 600));

      final Rect artwork = _artworkRect(tester);
      expect(artwork.right, lessThanOrEqualTo(_controlsRect(tester).left));
      expect(artwork.height, lessThan(600));
      expect(tester.takeException(), isNull);
    });

    testWidgets('scaled-up text does not overflow the side-by-side layout',
        (tester) async {
      await _pumpPlayer(
        tester,
        size: const Size(1280, 800),
        textScaler: const TextScaler.linear(2.0),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Song One'), findsOneWidget);
      expect(find.byTooltip('Pause'), findsOneWidget);
    });

    testWidgets('short wide lyrics keep usable height at 2x text scale',
        (tester) async {
      await _pumpPlayer(
        tester,
        size: const Size(1280, 600),
        lyrics: _lyrics,
        textScaler: const TextScaler.linear(2.0),
      );

      await tester.tap(find.byTooltip('Lyrics'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('track_metadata_compact_height')),
        findsOneWidget,
      );
      expect(find.byType(LyricsView), findsOneWidget);
      expect(tester.getRect(find.byType(LyricsView)).height, greaterThan(80));
      expect(find.byTooltip('Pause'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('resizing keeps playback and the lyrics toggle',
        (tester) async {
      await _pumpPlayer(
        tester,
        size: const Size(1280, 800),
        lyrics: _lyrics,
      );

      await tester.tap(find.byTooltip('Lyrics'));
      await tester.pumpAndSettle();

      for (final Size size in <Size>[
        const Size(800, 800),
        const Size(390, 844),
        const Size(1920, 1080),
        const Size(3440, 1440),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'at $size');
        expect(find.byType(LyricsView), findsOneWidget, reason: 'at $size');
        expect(find.byTooltip('Pause'), findsOneWidget, reason: 'at $size');
      }
    });

    testWidgets('an ultrawide window stops stretching the two columns apart',
        (tester) async {
      await _pumpPlayer(tester, size: const Size(3440, 1440));

      final Rect artwork = _artworkRect(tester);
      final Rect controls = _controlsRect(tester);
      expect(artwork.left, greaterThan(400));
      expect(controls.right, lessThan(3040));
      expect(tester.takeException(), isNull);
    });
  });
}
