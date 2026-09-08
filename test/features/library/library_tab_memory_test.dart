import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/library_tab_store.dart';
import 'package:linthra/data/repositories/download_repository_provider.dart';
import 'package:linthra/data/repositories/in_memory_library_tab_store.dart';
import 'package:linthra/data/repositories/library_tab_store_provider.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/features/library/library_screen.dart';

import 'fake_music_library_repository.dart';
import 'fake_remote_track_downloader.dart';

const List<Track> _tracks = <Track>[
  Track(id: 'a', title: 'Song A', uri: 'file:///a.mp3'),
  Track(id: 'b', title: 'Song B', uri: 'file:///b.mp3'),
];

Future<void> _pump(WidgetTester tester, LibraryTabStore store) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        musicLibraryRepositoryProvider
            .overrideWithValue(FakeMusicLibraryRepository(tracks: _tracks)),
        remoteTrackDownloaderProvider
            .overrideWithValue(FakeRemoteTrackDownloader()),
        libraryTabStoreProvider.overrideWithValue(store),
      ],
      child: const MaterialApp(home: LibraryScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

/// Which tab the TabBar is actually showing.
int _currentTab(WidgetTester tester) {
  return tester.widget<TabBar>(find.byType(TabBar)).controller!.index;
}

void main() {
  group('Library remembers its tab (#580)', () {
    testWidgets('a fresh install opens on the first tab', (tester) async {
      await _pump(tester, InMemoryLibraryTabStore());

      expect(_currentTab(tester), 0);
    });

    testWidgets('reopens on the tab last used', (tester) async {
      // What a previous session left behind for someone who browses by album.
      await _pump(tester, InMemoryLibraryTabStore('albums'));

      expect(_currentTab(tester), 1);
    });

    testWidgets('switching tabs persists the choice', (tester) async {
      final InMemoryLibraryTabStore store = InMemoryLibraryTabStore();
      await _pump(tester, store);

      await tester.tap(find.text('Artists'));
      await tester.pumpAndSettle();

      expect(await store.read(), 'artists');
    });

    testWidgets('a stored tab that no longer exists falls back to the first',
        (tester) async {
      // A rename or a removed tab must not leave the screen pointing at
      // nothing, which is why the name is stored rather than the index.
      await _pump(tester, InMemoryLibraryTabStore('genres'));

      expect(_currentTab(tester), 0);
    });
  });
}
