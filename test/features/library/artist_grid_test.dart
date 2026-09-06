import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/app/routes.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/in_memory_playlist_store.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/playlist_repository_provider.dart';
import 'package:linthra/features/library/artist_detail_screen.dart';
import 'package:linthra/features/library/library_screen.dart';
import 'package:linthra/features/library/widgets/artist_grid.dart';
import 'package:linthra/features/library/widgets/artist_tile.dart';
import 'package:linthra/features/player/player_providers.dart';

import '../player/fake_playback_controller.dart';
import 'fake_music_library_repository.dart';

List<Track> _artists() => <Track>[
      for (int i = 0; i < 6; i++)
        Track(
          id: 'a$i',
          title: 'Song $i',
          uri: 'jellyfin:a$i',
          artistName: 'Artist $i',
          albumName: 'Album $i',
        ),
    ];

GoRouter _router() {
  return GoRouter(
    initialLocation: AppRoutes.library,
    routes: <RouteBase>[
      GoRoute(
        path: AppRoutes.library,
        builder: (_, __) => const LibraryScreen(),
      ),
      GoRoute(
        path: '/library/artist/:id',
        builder: (_, GoRouterState s) =>
            ArtistDetailScreen(artistId: s.pathParameters['id']!),
      ),
    ],
  );
}

Future<void> _pumpArtists(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        musicLibraryRepositoryProvider.overrideWithValue(
          FakeMusicLibraryRepository(tracks: _artists()),
        ),
        playlistStoreProvider.overrideWithValue(InMemoryPlaylistStore()),
        playbackControllerProvider.overrideWithValue(FakePlaybackController()),
      ],
      child: MediaQuery(
        data: MediaQueryData(textScaler: textScaler),
        child: MaterialApp.router(routerConfig: _router()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Artists'));
  await tester.pumpAndSettle();
}

List<Rect> _firstRow(WidgetTester tester) {
  final List<Rect> rects = tester.elementList(find.byType(ArtistTile)).map(
    (Element e) {
      final RenderBox box = e.renderObject! as RenderBox;
      return box.localToGlobal(Offset.zero) & box.size;
    },
  ).toList();
  final double top = rects
      .map((Rect r) => r.top)
      .reduce((double a, double b) => a < b ? a : b);
  return <Rect>[
    for (final Rect r in rects)
      if (r.top == top) r,
  ]..sort((Rect a, Rect b) => a.left.compareTo(b.left));
}

void main() {
  group('artistGridColumnCount', () {
    test('a phone stays a single-column list', () {
      expect(artistGridColumnCount(360), 1);
      expect(artistGridColumnCount(390), 1);
      expect(artistGridColumnCount(430), 1);
    });

    test('a second column waits for padding and its inter-column gutter', () {
      expect(artistGridColumnCount(680), 1);
      expect(artistGridColumnCount(703), 1);
      expect(artistGridColumnCount(704), 2);
      expect(artistGridColumnCount(1040), 2);
    });

    test('desktop widths flow rows into columns', () {
      expect(artistGridColumnCount(1168), 3); // 1280x720
      expect(artistGridColumnCount(1808), 4); // 1920x1080
      expect(artistGridColumnCount(2448), 5); // 2560x1440
    });

    test('common 4K width grows beyond the old six-column cap', () {
      expect(artistGridColumnCount(3700), 7);
      expect(artistGridColumnCount(3700), greaterThan(6));
    });

    test('multi-column rows honor the declared 340-520 width band', () {
      const double horizontalPadding = 16;
      const double gutter = 8;
      for (final double width in <double>[
        704,
        1040,
        1168,
        1808,
        2448,
        3300,
        3700,
      ]) {
        final int columns = artistGridColumnCount(width);
        final double rowWidth =
            (width - horizontalPadding - gutter * (columns - 1)) / columns;
        expect(
          rowWidth,
          greaterThanOrEqualTo(340),
          reason: 'minimum at $width with $columns columns',
        );
        expect(
          rowWidth,
          lessThanOrEqualTo(520),
          reason: 'maximum at $width with $columns columns',
        );
      }
    });

    test('a degenerate width still renders one column', () {
      expect(artistGridColumnCount(0), 1);
      expect(artistGridColumnCount(-10), 1);
      expect(artistGridColumnCount(double.infinity), 1);
    });
  });

  group('Artists tab', () {
    testWidgets('a phone shows one artist per row', (tester) async {
      await _pumpArtists(tester);

      expect(find.byKey(const Key('library_artist_list')), findsOneWidget);
      expect(_firstRow(tester).length, 1);
      expect(find.text('Artist 0'), findsOneWidget);
    });

    testWidgets('a desktop window puts several artists on a row',
        (tester) async {
      await _pumpArtists(tester, size: const Size(1920, 1080));

      final List<Rect> row = _firstRow(tester);
      expect(row.length, greaterThan(2));
      for (final Rect tile in row) {
        expect(tile.width, lessThan(600));
      }
      expect(row.last.right, lessThanOrEqualTo(1920));
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping an artist still opens them', (tester) async {
      await _pumpArtists(tester, size: const Size(1280, 800));

      await tester.tap(find.text('Artist 3'));
      await tester.pumpAndSettle();

      expect(find.text('Play all'), findsOneWidget);
      expect(find.text('Song 3'), findsOneWidget);
    });

    testWidgets('long-pressing an artist still offers their songs',
        (tester) async {
      await _pumpArtists(tester, size: const Size(1280, 800));

      await tester.longPress(find.text('Artist 1'));
      await tester.pumpAndSettle();

      expect(find.text('Add to playlist'), findsOneWidget);
      expect(find.text('New playlist'), findsOneWidget);
    });

    testWidgets('scaled-up text gets the room it needs', (tester) async {
      await _pumpArtists(
        tester,
        size: const Size(1280, 800),
        textScaler: const TextScaler.linear(2.0),
      );

      expect(tester.takeException(), isNull);
      expect(find.byType(ArtistTile), findsWidgets);
    });

    testWidgets('resizing reflows the rows without overflow', (tester) async {
      await _pumpArtists(tester);

      for (final Size size in <Size>[
        const Size(800, 720),
        const Size(1280, 720),
        const Size(2560, 1440),
        const Size(3440, 1440),
        const Size(3840, 2160),
        const Size(390, 844),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'at $size');
        expect(
          _firstRow(tester).last.right,
          lessThanOrEqualTo(size.width),
          reason: 'at $size',
        );
      }
    });
  });
}
