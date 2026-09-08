import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/download_repository_provider.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/features/library/library_screen.dart';
import 'package:linthra/features/library/widgets/alphabet_track_list.dart';
import 'package:linthra/features/library/widgets/track_tile.dart';

import 'fake_music_library_repository.dart';
import 'fake_remote_track_downloader.dart';

const List<Track> _mixed = <Track>[
  Track(id: 'a', title: 'Song A', uri: 'file:///a.mp3'),
  Track(id: 'b', title: 'Song B', uri: 'jellyfin:b'),
];

// Enough rows that the list scrolls well past a phone screen, which is the
// precondition in #582 ("more than 7 songs was enough on my phone").
final List<Track> _long = <Track>[
  for (int i = 0; i < 60; i++)
    Track(
      id: 'song-$i',
      // Zero-padded so the visual order matches the index and a row can be
      // found by name after scrolling.
      title: 'Song ${i.toString().padLeft(2, '0')}',
      uri: 'jellyfin:song-$i',
    ),
];

// Two unrelated songs that share a bare server-side id across providers.
const List<Track> _sameBareId = <Track>[
  Track(id: '101', title: 'Alpha', uri: 'jellyfin:101'),
  Track(id: '101', title: 'Beta', uri: 'subsonic:101'),
];

Future<FakeMusicLibraryRepository> _pump(
  WidgetTester tester, {
  List<Track> tracks = _mixed,
}) async {
  final FakeMusicLibraryRepository repository =
      FakeMusicLibraryRepository(tracks: tracks);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        musicLibraryRepositoryProvider.overrideWithValue(repository),
        remoteTrackDownloaderProvider
            .overrideWithValue(FakeRemoteTrackDownloader()),
      ],
      child: const MaterialApp(home: LibraryScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return repository;
}

void main() {
  group('Library multi-select', () {
    testWidgets('entering selection keeps the list where it was (#582)',
        (tester) async {
      await _pump(tester, tracks: _long);

      final Finder scrollable = find
          .descendant(
            of: find.byType(AlphabetTrackList),
            matching: find.byType(Scrollable),
          )
          .first;

      // Scroll away from the top, the way someone with a large library does
      // before long-pressing a row.
      await tester.drag(scrollable, const Offset(0, -900));
      await tester.pumpAndSettle();
      final double before =
          tester.state<ScrollableState>(scrollable).position.pixels;
      expect(before, greaterThan(0), reason: 'the drag should have scrolled');

      // Long-press whichever row is now under the finger, not a fixed title:
      // what matters is that selection starts from a scrolled list.
      final Finder row = find.byType(TrackTile).first;
      await tester.longPress(row);
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);

      // The regression: the list used to be rebuilt from scratch here, so the
      // offset went back to 0 and the user lost their place.
      final double after =
          tester.state<ScrollableState>(scrollable).position.pixels;
      expect(after, before);
    });

    testWidgets('leaving selection also keeps the position (#582)',
        (tester) async {
      await _pump(tester, tracks: _long);

      final Finder scrollable = find
          .descendant(
            of: find.byType(AlphabetTrackList),
            matching: find.byType(Scrollable),
          )
          .first;

      await tester.drag(scrollable, const Offset(0, -900));
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(TrackTile).first);
      await tester.pumpAndSettle();
      final double selecting =
          tester.state<ScrollableState>(scrollable).position.pixels;

      await tester.tap(find.byTooltip('Cancel selection'));
      await tester.pumpAndSettle();

      expect(find.text('1 selected'), findsNothing);
      // Both halves matter. Without the greaterThan, a reset on the way *in*
      // would make the equality below trivially true (0 == 0) and this test
      // would guard nothing.
      expect(selecting, greaterThan(0));
      expect(
        tester.state<ScrollableState>(scrollable).position.pixels,
        selecting,
      );
    });

    testWidgets('long-press enters selection mode and shows the count',
        (tester) async {
      await _pump(tester);

      await tester.longPress(find.text('Song A'));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);

      await tester.tap(find.text('Song B'));
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);
    });

    testWidgets(
        'same bare-id rows from different providers select independently',
        (tester) async {
      await _pump(tester, tracks: _sameBareId);

      // Long-press one of the two same-id rows: only it is selected, because
      // selection keys on the provider-namespaced uri, not the bare id.
      await tester.longPress(find.text('Alpha'));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);
      expect(find.text('2 selected'), findsNothing);
    });

    testWidgets('offers safe actions and hides unsafe destructive deletes',
        (tester) async {
      await _pump(tester);
      await tester.longPress(find.text('Song A'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Song B'));
      await tester.pumpAndSettle();

      // Safe, reversible actions are offered.
      expect(find.byTooltip('Add to playlist'), findsOneWidget);
      expect(find.byTooltip('Remove from Linthra'), findsOneWidget);
      // The Jellyfin track in the selection means offline-copy removal applies.
      expect(find.byTooltip('Remove offline copies'), findsOneWidget);
      // Destructive file/server deletes are never offered in this release.
      expect(find.byTooltip('Delete from server'), findsNothing);
      expect(find.byTooltip('Delete files'), findsNothing);
    });

    testWidgets('a local-only selection hides the offline-copy action',
        (tester) async {
      await _pump(
        tester,
        tracks: const <Track>[
          Track(id: 'a', title: 'Song A', uri: 'file:///a.mp3'),
        ],
      );
      await tester.longPress(find.text('Song A'));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Remove from Linthra'), findsOneWidget);
      expect(find.byTooltip('Remove offline copies'), findsNothing);
    });

    testWidgets('bulk remove asks for confirmation showing the count',
        (tester) async {
      final FakeMusicLibraryRepository repository = await _pump(tester);
      await tester.longPress(find.text('Song A'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Song B'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Remove from Linthra'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Remove 2 songs from Linthra?'),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Remove'), findsOneWidget);

      // Confirming removes only from the index (the fake records the uris — the
      // catalog's provider-namespaced identity, not the bare id).
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();
      expect(
        repository.removedTrackUris,
        containsAll(<String>['file:///a.mp3', 'jellyfin:b']),
      );
    });
  });
}
