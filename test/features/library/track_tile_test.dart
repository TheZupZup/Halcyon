import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/download_repository.dart';
import 'package:linthra/data/repositories/download_repository_provider.dart';
import 'package:linthra/features/downloads/download_providers.dart';
import 'package:linthra/features/library/widgets/track_tile.dart';
import 'package:linthra/features/player/player_providers.dart';

import '../player/fake_playback_controller.dart';
import 'fake_remote_track_downloader.dart';

Future<void> _pump(
  WidgetTester tester,
  List<Track> tracks, {
  FakePlaybackController? controller,
  TextScaler? textScaler,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        remoteTrackDownloaderProvider
            .overrideWithValue(FakeRemoteTrackDownloader()),
        if (controller != null)
          playbackControllerProvider.overrideWithValue(controller),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (BuildContext context) {
            final Widget scaffold = Scaffold(
              body: ListView(
                children: [
                  for (var i = 0; i < tracks.length; i++)
                    TrackTile(tracks: tracks, index: i),
                ],
              ),
            );
            if (textScaler == null) return scaffold;
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: textScaler),
              child: scaffold,
            );
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Shrinks the test surface to a narrow phone for the crowding checks, and
/// restores it afterwards.
void _useNarrowPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(320 * 3, 640 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

void main() {
  group('TrackTile', () {
    testWidgets('shows the title and a clean artist • album subtitle', (
      tester,
    ) async {
      await _pump(tester, const <Track>[
        Track(
          id: '1',
          title: 'Song One',
          uri: 'file:///s1.mp3',
          artistName: 'Artist A',
          albumName: 'Album X',
        ),
      ]);

      expect(find.text('Song One'), findsOneWidget);
      expect(find.text('Artist A • Album X'), findsOneWidget);
    });

    testWidgets('falls back to the uri when metadata is missing', (
      tester,
    ) async {
      await _pump(tester, const <Track>[
        Track(id: '2', title: 'Song Two', uri: 'file:///s2.mp3'),
      ]);

      expect(find.text('Song Two'), findsOneWidget);
      expect(find.text('file:///s2.mp3'), findsOneWidget);
    });

    testWidgets('exposes a trailing overflow menu', (tester) async {
      await _pump(tester, const <Track>[
        Track(id: '1', title: 'Song One', uri: 'file:///s1.mp3'),
      ]);

      expect(find.byTooltip('More actions'), findsOneWidget);
      // No dedicated, always-visible download button on the row anymore.
      expect(find.byTooltip('Download'), findsNothing);
    });

    testWidgets('overflow menu offers add-to-playlist and remove-from-Linthra',
        (tester) async {
      await _pump(tester, const <Track>[
        Track(id: '1', title: 'Song One', uri: 'file:///s1.mp3'),
      ]);

      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();

      expect(find.text('Add to playlist'), findsOneWidget);
      expect(find.text('Remove from Linthra'), findsOneWidget);
    });

    testWidgets('overflow menu offers queue actions', (tester) async {
      await _pump(tester, const <Track>[
        Track(id: '1', title: 'Song One', uri: 'file:///s1.mp3'),
      ]);

      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();

      expect(find.text('Play next'), findsOneWidget);
      expect(find.text('Add to queue'), findsOneWidget);
    });

    testWidgets(
        'overflow menu offers Add to favorites with an outline heart when not '
        'favorited', (tester) async {
      await _pump(tester, const <Track>[
        Track(id: '1', title: 'Song One', uri: 'file:///s1.mp3'),
      ]);

      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();

      expect(find.text('Add to favorites'), findsOneWidget);
      expect(find.text('Remove from favorites'), findsNothing);
      // Two outline hearts while the menu is open: the row's own visible
      // toggle, plus the menu entry that remains as the secondary path.
      expect(find.byIcon(Icons.favorite_border), findsNWidgets(2));
    });

    testWidgets(
        'choosing Add to favorites likes the track and flips to a filled-heart '
        'Remove — without starting playback or changing the queue',
        (tester) async {
      final FakePlaybackController controller = FakePlaybackController();
      await _pump(
        tester,
        const <Track>[Track(id: '1', title: 'Song One', uri: 'file:///s1.mp3')],
        controller: controller,
      );

      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add to favorites'));
      await tester.pumpAndSettle();

      // Favoriting is a pure like: no track played, no queue change.
      expect(controller.playedTracks, isEmpty);
      expect(controller.state.upNext, isEmpty);

      // Reopening the menu now shows the filled-heart "Remove from favorites".
      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();
      expect(find.text('Remove from favorites'), findsOneWidget);
      expect(find.text('Add to favorites'), findsNothing);
      // Row toggle + menu entry, both now filled (see the outline case above).
      expect(find.byIcon(Icons.favorite), findsNWidgets(2));
    });
  });

  group('TrackTile visible favorite heart', () {
    testWidgets('every row shows an outline heart when not favorited',
        (tester) async {
      await _pump(tester, const <Track>[
        Track(id: '1', title: 'Song One', uri: 'file:///s1.mp3'),
        Track(id: '2', title: 'Song Two', uri: 'file:///s2.mp3'),
      ]);

      // Visible without opening any menu — the whole point of the change.
      expect(find.byTooltip('Add to favorites'), findsNWidgets(2));
      expect(find.byIcon(Icons.favorite_border), findsNWidgets(2));
      expect(find.byIcon(Icons.favorite), findsNothing);
    });

    testWidgets('tapping the heart favorites the track and fills it',
        (tester) async {
      final FakePlaybackController controller = FakePlaybackController();
      await _pump(
        tester,
        const <Track>[Track(id: '1', title: 'Song One', uri: 'file:///s1.mp3')],
        controller: controller,
      );

      await tester.tap(find.byTooltip('Add to favorites'));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.favorite), findsOneWidget);
      expect(find.byIcon(Icons.favorite_border), findsNothing);
      expect(find.byTooltip('Remove from favorites'), findsOneWidget);
      // Liking is a pure like: nothing plays and the queue is untouched.
      expect(controller.playedTracks, isEmpty);
      expect(controller.state.upNext, isEmpty);
    });

    testWidgets('tapping a filled heart unfavorites the track', (tester) async {
      await _pump(tester, const <Track>[
        Track(id: '1', title: 'Song One', uri: 'file:///s1.mp3'),
      ]);

      await tester.tap(find.byTooltip('Add to favorites'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Remove from favorites'));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.favorite_border), findsOneWidget);
      expect(find.byIcon(Icons.favorite), findsNothing);
    });

    testWidgets('only the tapped row is favorited, not its neighbours',
        (tester) async {
      await _pump(tester, const <Track>[
        Track(id: '1', title: 'Song One', uri: 'file:///s1.mp3'),
        Track(id: '2', title: 'Song Two', uri: 'file:///s2.mp3'),
      ]);

      await tester.tap(find.byTooltip('Add to favorites').first);
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.favorite), findsOneWidget);
      expect(find.byIcon(Icons.favorite_border), findsOneWidget);
    });

    testWidgets('two provider copies of one id keep separate hearts',
        (tester) async {
      // Favourites are keyed by the provider-namespaced uri, so liking the
      // Jellyfin copy must not light up the Navidrome one.
      await _pump(tester, const <Track>[
        Track(id: '101', title: 'Shared', uri: 'jellyfin:101'),
        Track(id: '101', title: 'Shared', uri: 'subsonic:101'),
      ]);

      await tester.tap(find.byTooltip('Add to favorites').first);
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.favorite), findsOneWidget);
      expect(find.byIcon(Icons.favorite_border), findsOneWidget);
    });

    testWidgets('the heart does not replace the overflow menu', (tester) async {
      await _pump(tester, const <Track>[
        Track(id: '1', title: 'Song One', uri: 'file:///s1.mp3'),
      ]);

      // Both paths coexist: the menu keeps its favourite entry as the
      // secondary route.
      expect(find.byTooltip('Add to favorites'), findsOneWidget);
      expect(find.byTooltip('More actions'), findsOneWidget);

      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();
      expect(find.text('Add to favorites'), findsOneWidget);
    });

    testWidgets('selection mode hides the heart in favour of the checkbox',
        (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            remoteTrackDownloaderProvider
                .overrideWithValue(FakeRemoteTrackDownloader()),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: TrackTile(
                tracks: <Track>[
                  Track(id: '1', title: 'Song One', uri: 'file:///s1.mp3'),
                ],
                index: 0,
                selectable: true,
                selectionActive: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(Checkbox), findsOneWidget);
      expect(find.byTooltip('Add to favorites'), findsNothing);
      expect(find.byTooltip('More actions'), findsNothing);
    });
  });

  group('TrackTile row layout under pressure', () {
    testWidgets('a very long title and subtitle do not overflow a narrow row',
        (tester) async {
      _useNarrowPhone(tester);
      await _pump(tester, const <Track>[
        Track(
          id: '1',
          title: 'An Extraordinarily Long Song Title That Keeps Going Well '
              'Past Any Reasonable Width For A Phone Screen',
          uri: 'file:///s1.mp3',
          artistName: 'A Band With An Unreasonably Long Name Indeed',
          albumName: 'And An Album Title That Is Similarly Overlong',
        ),
      ]);

      // No RenderFlex overflow from the trailing glyph + heart + menu row.
      expect(tester.takeException(), isNull);
      // Both controls survive, and the text ellipsizes rather than pushing.
      expect(find.byTooltip('Add to favorites'), findsOneWidget);
      expect(find.byTooltip('More actions'), findsOneWidget);
      final Text title = tester.widget<Text>(
        find.textContaining('An Extraordinarily Long Song Title'),
      );
      expect(title.maxLines, 1);
      expect(title.overflow, TextOverflow.ellipsis);
    });

    testWidgets('the row survives a 2.0 text scale without overflowing',
        (tester) async {
      _useNarrowPhone(tester);
      await _pump(
        tester,
        const <Track>[
          Track(
            id: '1',
            title: 'Song One',
            uri: 'file:///s1.mp3',
            artistName: 'Artist A',
            albumName: 'Album X',
          ),
        ],
        textScaler: const TextScaler.linear(2.0),
      );

      expect(tester.takeException(), isNull);
      expect(find.byTooltip('Add to favorites'), findsOneWidget);
      expect(find.byTooltip('More actions'), findsOneWidget);
    });

    testWidgets('the heart groups with the menu, not the download glyph',
        (tester) async {
      // Proximity is what makes the trailing edge read as one action group.
      // Centred in its box the heart measured 12dp from the status glyph and
      // 24dp from the menu — visually part of the *status* cluster. It is now
      // right-aligned inside the same box, which flips that.
      _useNarrowPhone(tester);
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            remoteTrackDownloaderProvider
                .overrideWithValue(FakeRemoteTrackDownloader()),
            // A downloaded remote track, so the status glyph is actually drawn.
            trackDownloadStatusProvider.overrideWith(
              (ref, key) =>
                  Stream<DownloadStatus>.value(DownloadStatus.downloaded),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: TrackTile(
                tracks: <Track>[
                  Track(id: '1', title: 'Song One', uri: 'jellyfin:1'),
                ],
                index: 0,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final Rect glyph = tester.getRect(find.byIcon(Icons.download_done));
      final Rect heart = tester.getRect(find.byIcon(Icons.favorite_border));
      final Rect menu = tester.getRect(find.byIcon(Icons.more_vert));

      final double toMenu = menu.left - heart.right;
      final double toGlyph = heart.left - glyph.right;
      expect(
        toMenu,
        lessThan(toGlyph),
        reason: 'the heart must sit closer to the overflow menu ($toMenu) '
            'than to the download glyph ($toGlyph)',
      );

      // Grouping is a pure re-alignment inside the existing box, so the tap
      // target must not have shrunk — otherwise we'd have traded accessibility
      // for looks. IconButton pads the hit area out to Material's 48dp minimum
      // around the 40dp visual box, so this floor is what a finger actually
      // gets.
      final Size target = tester.getSize(
        find
            .ancestor(
              of: find.byIcon(Icons.favorite_border),
              matching: find.byType(IconButton),
            )
            .first,
      );
      expect(target.width, greaterThanOrEqualTo(48));
      expect(target.height, greaterThanOrEqualTo(48));
    });

    testWidgets('the heart stays tappable at a 2.0 text scale', (tester) async {
      _useNarrowPhone(tester);
      await _pump(
        tester,
        const <Track>[Track(id: '1', title: 'Song One', uri: 'file:///s1.mp3')],
        textScaler: const TextScaler.linear(2.0),
      );

      // A control that renders but can't be hit is no better than a hidden one.
      await tester.tap(find.byTooltip('Add to favorites'));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.favorite), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('TrackTile selection', () {
    testWidgets('long-press starts selection', (tester) async {
      Track? started;
      await _pumpSelectable(
        tester,
        selectionActive: false,
        onSelectStart: (Track t) => started = t,
      );

      await tester.longPress(find.text('Song One'));
      await tester.pumpAndSettle();
      expect(started?.id, '1');
    });

    testWidgets('shows a checkbox and toggles while selecting', (tester) async {
      Track? toggled;
      await _pumpSelectable(
        tester,
        selectionActive: true,
        selected: false,
        onSelectToggle: (Track t) => toggled = t,
      );

      expect(find.byType(Checkbox), findsOneWidget);
      await tester.tap(find.text('Song One'));
      await tester.pumpAndSettle();
      expect(toggled?.id, '1');
    });
  });
}

Future<void> _pumpSelectable(
  WidgetTester tester, {
  required bool selectionActive,
  bool selected = false,
  void Function(Track track)? onSelectStart,
  void Function(Track track)? onSelectToggle,
}) async {
  const List<Track> tracks = <Track>[
    Track(id: '1', title: 'Song One', uri: 'file:///s1.mp3'),
  ];
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        remoteTrackDownloaderProvider
            .overrideWithValue(FakeRemoteTrackDownloader()),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: TrackTile(
            tracks: tracks,
            index: 0,
            selectable: true,
            selectionActive: selectionActive,
            selected: selected,
            onSelectStart:
                onSelectStart == null ? null : () => onSelectStart(tracks[0]),
            onSelectToggle:
                onSelectToggle == null ? null : () => onSelectToggle(tracks[0]),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
