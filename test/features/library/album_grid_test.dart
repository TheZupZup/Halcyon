import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/app/routes.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/in_memory_playlist_store.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/playlist_repository_provider.dart';
import 'package:linthra/features/library/album_detail_screen.dart';
import 'package:linthra/features/library/library_screen.dart';
import 'package:linthra/features/library/widgets/album_grid.dart';
import 'package:linthra/features/library/widgets/album_grid_card.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/widgets/album_artwork.dart';

import '../player/fake_playback_controller.dart';
import 'fake_music_library_repository.dart';

// No artworkUri anywhere, so these widget tests never reach for the network:
// every cover falls back to the placeholder, which is also the "album without
// artwork" case exercised below.
const List<Track> _tracks = <Track>[
  Track(
    id: '1',
    title: 'Alpha',
    uri: 'jellyfin:1',
    artistName: 'Daft Punk',
    albumName: 'Discovery',
  ),
  Track(
    id: '2',
    title: 'Beta',
    uri: 'jellyfin:2',
    artistName: 'Daft Punk',
    albumName: 'Discovery',
  ),
  Track(
    id: '3',
    title: 'Gamma',
    uri: 'jellyfin:3',
    artistName: 'Adele',
    albumName: '25',
  ),
];

/// Six albums, enough rows to tell two columns from three or four.
List<Track> _manyAlbums() => <Track>[
      for (int i = 0; i < 6; i++)
        Track(
          id: 'many-$i',
          title: 'Song $i',
          uri: 'jellyfin:many-$i',
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
        path: '/library/album/:id',
        builder: (_, GoRouterState s) =>
            AlbumDetailScreen(albumId: s.pathParameters['id']!),
      ),
    ],
  );
}

/// Pumps the Library at a given logical screen size and lands on Albums.
Future<void> _pumpAlbums(
  WidgetTester tester, {
  List<Track>? tracks,
  Size size = const Size(390, 844), // a typical phone
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        musicLibraryRepositoryProvider.overrideWithValue(
          FakeMusicLibraryRepository(tracks: tracks ?? _tracks),
        ),
        playlistStoreProvider.overrideWithValue(InMemoryPlaylistStore()),
        playbackControllerProvider.overrideWithValue(FakePlaybackController()),
      ],
      child: MaterialApp.router(routerConfig: _router()),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Albums'));
  await tester.pumpAndSettle();
}

/// On-screen rectangles of every laid-out album card.
List<Rect> _cardRects(WidgetTester tester) {
  return tester.elementList(find.byType(AlbumGridCard)).map((Element e) {
    final RenderBox box = e.renderObject! as RenderBox;
    return box.localToGlobal(Offset.zero) & box.size;
  }).toList();
}

/// The cards sharing the topmost row, left to right.
List<Rect> _firstRow(WidgetTester tester) {
  final List<Rect> rects = _cardRects(tester);
  final double top = rects
      .map((Rect r) => r.top)
      .reduce((double a, double b) => a < b ? a : b);
  return <Rect>[
    for (final Rect r in rects)
      if (r.top == top) r,
  ]..sort((Rect a, Rect b) => a.left.compareTo(b.left));
}

void main() {
  group('albumGridColumnCount', () {
    test('a phone-width content box gets exactly two columns', () {
      expect(albumGridColumnCount(328), 2); // 360dp phone, minus padding
      expect(albumGridColumnCount(358), 2); // 390dp phone, minus padding
      expect(albumGridColumnCount(398), 2); // 430dp phone, minus padding
    });

    test('a third column only lands once there is room for one', () {
      expect(albumGridColumnCount(560), 2);
      expect(albumGridColumnCount(600), 3);
      expect(albumGridColumnCount(800), 4);
    });

    test('columns are capped so covers never shrink to thumbnails', () {
      expect(albumGridColumnCount(4000), 6);
    });

    test('a degenerate width still renders two columns', () {
      expect(albumGridColumnCount(0), 2);
      expect(albumGridColumnCount(-10), 2);
      expect(albumGridColumnCount(double.infinity), 2);
    });
  });

  group('Albums grid', () {
    testWidgets('albums render as grid cards, not list rows', (tester) async {
      await _pumpAlbums(tester);

      expect(find.byKey(const Key('library_album_grid')), findsOneWidget);
      expect(find.byType(GridView), findsOneWidget);
      expect(find.byType(AlbumGridCard), findsNWidgets(2));
      expect(find.text('Discovery'), findsOneWidget);
      expect(find.text('25'), findsOneWidget);
      expect(find.text('Daft Punk'), findsOneWidget);
      expect(find.text('Adele'), findsOneWidget);
    });

    testWidgets('two cards fit side by side on a typical phone width',
        (tester) async {
      await _pumpAlbums(tester, tracks: _manyAlbums());

      final List<Rect> row = _firstRow(tester);
      expect(row.length, 2);

      // Both cards are on screen, side by side, and each is wide enough to read.
      expect(row.first.left, lessThan(row.last.left));
      expect(row.last.right, lessThanOrEqualTo(390));
      expect(row.first.width, greaterThan(120));
    });

    testWidgets('artwork stays square', (tester) async {
      await _pumpAlbums(tester);

      final Rect art = tester.getRect(
        find
            .descendant(
              of: find.byType(AlbumGridCard),
              matching: find.byType(AlbumArtwork),
            )
            .first,
      );
      expect(art.width, closeTo(art.height, 0.5));
    });

    testWidgets('a wide window gets more columns than a phone', (tester) async {
      await _pumpAlbums(
        tester,
        tracks: _manyAlbums(),
        size: const Size(1280, 900),
      );

      expect(_firstRow(tester).length, greaterThan(2));
    });

    testWidgets('tapping a card opens that album', (tester) async {
      await _pumpAlbums(tester);

      await tester.tap(find.text('Discovery'));
      await tester.pumpAndSettle();

      // On the album detail screen, showing only Discovery's tracks.
      expect(find.text('Play'), findsOneWidget);
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);
      expect(find.text('Gamma'), findsNothing);
    });

    testWidgets('tapping the other card opens the other album', (tester) async {
      await _pumpAlbums(tester);

      await tester.tap(find.text('25'));
      await tester.pumpAndSettle();

      expect(find.text('Gamma'), findsOneWidget);
      expect(find.text('Alpha'), findsNothing);
    });

    testWidgets(
        'long-pressing a card still offers the whole album to a '
        'playlist', (tester) async {
      await _pumpAlbums(tester);

      await tester.longPress(find.text('Discovery'));
      await tester.pumpAndSettle();

      expect(find.text('Add 2 songs to playlist'), findsOneWidget);
      expect(find.text('New playlist'), findsOneWidget);
    });

    testWidgets('search still filters the grid', (tester) async {
      await _pumpAlbums(tester);

      await tester.enterText(
        find.byKey(const Key('library_search_field')),
        'adele',
      );
      await tester.pumpAndSettle();

      expect(find.byType(AlbumGridCard), findsOneWidget);
      expect(find.text('25'), findsOneWidget);
      expect(find.text('Discovery'), findsNothing);
    });

    testWidgets('a query with no matches still shows the empty state',
        (tester) async {
      await _pumpAlbums(tester);

      await tester.enterText(
        find.byKey(const Key('library_search_field')),
        'zzzzz',
      );
      await tester.pumpAndSettle();

      expect(find.text('No results found.'), findsOneWidget);
      expect(find.byType(AlbumGridCard), findsNothing);
    });

    testWidgets('a long title and artist are clipped, never overflowing',
        (tester) async {
      await _pumpAlbums(
        tester,
        tracks: const <Track>[
          Track(
            id: 'long',
            title: 'Song',
            uri: 'jellyfin:long',
            artistName: 'An Extremely Long Recording Artist Name That Will Not '
                'Fit On One Line Of A Grid Card',
            albumName: 'An Extraordinarily Long Album Title That Runs Well '
                'Past Two Lines Of Any Reasonable Grid Card',
          ),
        ],
      );

      // A RenderFlex/paragraph overflow surfaces as a pumped exception.
      expect(tester.takeException(), isNull);

      final Finder card = find.byType(AlbumGridCard);
      final Text title = tester.widget<Text>(
        find.descendant(of: card, matching: find.textContaining('Album Title')),
      );
      expect(title.maxLines, 2);
      expect(title.overflow, TextOverflow.ellipsis);

      final Text artist = tester.widget<Text>(
        find.descendant(of: card, matching: find.textContaining('Artist Name')),
      );
      expect(artist.maxLines, 1);
      expect(artist.overflow, TextOverflow.ellipsis);

      // The card still sits inside the viewport, text and all.
      expect(tester.getRect(card).bottom, lessThanOrEqualTo(844));
    });

    testWidgets('scaled-up text does not overflow a card', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            musicLibraryRepositoryProvider.overrideWithValue(
              FakeMusicLibraryRepository(tracks: _tracks),
            ),
            playlistStoreProvider.overrideWithValue(InMemoryPlaylistStore()),
            playbackControllerProvider
                .overrideWithValue(FakePlaybackController()),
          ],
          child: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
            child: MaterialApp.router(routerConfig: _router()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Albums'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(AlbumGridCard), findsNWidgets(2));
    });

    testWidgets('albums without artwork render the placeholder safely',
        (tester) async {
      await _pumpAlbums(tester);

      expect(tester.takeException(), isNull);
      expect(
        find.descendant(
          of: find.byType(AlbumGridCard),
          matching: find.byIcon(Icons.music_note),
        ),
        findsNWidgets(2),
      );
    });

    testWidgets('a card reads as one item to a screen reader', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pumpAlbums(tester);

      expect(
        find.bySemanticsLabel(RegExp(r'Discovery\s*\n?\s*Daft Punk')),
        findsOneWidget,
      );
      handle.dispose();
    });
  });
}
