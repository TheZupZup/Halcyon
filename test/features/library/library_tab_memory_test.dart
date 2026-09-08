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

/// A store whose read resolves only after [delay], so a test can act during the
/// window the real shared_preferences read leaves open.
class _SlowLibraryTabStore implements LibraryTabStore {
  _SlowLibraryTabStore(this._tabName, this.delay);

  final String? _tabName;
  final Duration delay;

  @override
  Future<String?> read() async {
    await Future<void>.delayed(delay);
    return _tabName;
  }

  @override
  Future<void> write(String? tabName) async {}
}

/// A store that fails the way a missing platform plugin or a full disk would.
class _FailingLibraryTabStore implements LibraryTabStore {
  @override
  Future<String?> read() async => throw StateError('no preference storage');

  @override
  Future<void> write(String? tabName) async =>
      throw StateError('no preference storage');
}

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

    testWidgets('a tab the user picked wins over a late restore',
        (tester) async {
      // The read is still in flight while the user taps around. Going away from
      // Songs and back leaves the index at zero again, so the index alone
      // cannot tell "untouched" from "deliberately back on Songs".
      await _pump(
        tester,
        _SlowLibraryTabStore('artists', const Duration(seconds: 2)),
      );

      await tester.tap(find.text('Albums'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Songs'));
      await tester.pumpAndSettle();

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();

      expect(_currentTab(tester), 0);
    });

    testWidgets('restoring clears a search typed before it landed',
        (tester) async {
      await _pump(
        tester,
        _SlowLibraryTabStore('albums', const Duration(seconds: 2)),
      );

      await tester.enterText(find.byType(TextField), 'blue');
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();

      // The restore moved to Albums, so the query typed against Songs must be
      // cleared, exactly as it is on any other tab change.
      expect(_currentTab(tester), 1);
      expect(tester.widget<TextField>(find.byType(TextField)).controller?.text,
          isEmpty);
    });

    testWidgets('a storage failure leaves the screen usable', (tester) async {
      await _pump(tester, _FailingLibraryTabStore());

      expect(_currentTab(tester), 0);
      expect(tester.takeException(), isNull);

      // The write fails too, and must not surface either.
      await tester.tap(find.text('Albums'));
      await tester.pumpAndSettle();

      expect(_currentTab(tester), 1);
      expect(tester.takeException(), isNull);
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
