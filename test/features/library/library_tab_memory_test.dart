import 'dart:async';

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

/// A store whose read resolves exactly when the test says so, for the windows
/// that are too short to hit with a delay: between a keystroke and the 300ms
/// search debounce, or while a long-press is being held.
class _ManualLibraryTabStore implements LibraryTabStore {
  final Completer<String?> _read = Completer<String?>();

  /// The value left in the store, so a test can check what a tap wrote back.
  String? stored;

  void completeWith(String? tabName) => _read.complete(tabName);

  @override
  Future<String?> read() => _read.future;

  @override
  Future<void> write(String? tabName) async => stored = tabName;
}

/// A store whose first write is slow and later ones instant, the shape that
/// lets a stale write land last when writes are allowed to race.
class _RacyWriteLibraryTabStore implements LibraryTabStore {
  int _writes = 0;

  /// The value left in the store once everything has settled.
  String? stored;

  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String? tabName) async {
    final bool first = _writes++ == 0;
    if (first) await Future<void>.delayed(const Duration(milliseconds: 300));
    stored = tabName;
  }
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

    testWidgets(
        'a restore landing inside the search debounce still clears the '
        'box', (tester) async {
      final _ManualLibraryTabStore store = _ManualLibraryTabStore();
      await _pump(tester, store);

      await tester.enterText(find.byType(TextField), 'blue');
      // Deliberately not waiting out the 300ms debounce: the field holds text
      // while the query it feeds is still empty, which is the window a check on
      // the query alone misses.
      store.completeWith('albums');
      await tester.pump();
      await tester.pumpAndSettle();

      expect(_currentTab(tester), 1);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        isEmpty,
      );
    });

    testWidgets('a restore does not move the tab out from under a selection',
        (tester) async {
      final _ManualLibraryTabStore store = _ManualLibraryTabStore();
      await _pump(tester, store);

      await tester.longPress(find.text('Song A'));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);

      // Selection replaces the app bar, hides the tab bar and blocks swiping,
      // so moving the tab underneath it would strand the user.
      store.completeWith('albums');
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('1 selected'), findsOneWidget);

      await tester.tap(find.byTooltip('Cancel selection'));
      await tester.pumpAndSettle();

      expect(_currentTab(tester), 0);
    });

    testWidgets(
        'a restore landing mid long-press does not strand the selection',
        (tester) async {
      final _ManualLibraryTabStore store = _ManualLibraryTabStore();
      await _pump(tester, store);

      // Pointer down, but the recognizer has not fired yet: at this instant
      // neither the selection flag nor the user-interaction flag is set, so
      // guarding the restore alone would let it move the tab under the gesture.
      final TestGesture gesture =
          await tester.startGesture(tester.getCenter(find.text('Song A')));
      store.completeWith('albums');
      await tester.pump();

      // Hold past the long-press timeout, then let go.
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(find.text('1 selected'), findsOneWidget);

      // Selection came from the songs list, so that is what it must be sitting
      // on when it ends.
      await tester.tap(find.byTooltip('Cancel selection'));
      await tester.pumpAndSettle();
      expect(_currentTab(tester), 0);
    });

    testWidgets('the last tab wins when writes overlap', (tester) async {
      final _RacyWriteLibraryTabStore store = _RacyWriteLibraryTabStore();
      await _pump(tester, store);

      // Faster than the store can write: two writes in flight at once.
      await tester.tap(find.text('Albums'));
      await tester.pump();
      await tester.tap(find.text('Artists'));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      // Letting them race would land the slow first write last and store the
      // tab the user had already left.
      expect(_currentTab(tester), 2);
      expect(store.stored, 'artists');
    });

    testWidgets('a restore does not hijack a swipe in progress',
        (tester) async {
      final _ManualLibraryTabStore store = _ManualLibraryTabStore();
      await _pump(tester, store);

      // Partway through a swipe that has not crossed the midpoint: the index
      // has not moved yet, so nothing has marked this as a user tab change.
      final TestGesture gesture =
          await tester.startGesture(tester.getCenter(find.byType(TabBarView)));
      await gesture.moveBy(const Offset(-60, 0));
      await tester.pump();

      store.completeWith('artists');
      await tester.pump();

      await gesture.up();
      await tester.pumpAndSettle();

      // The swipe fell short, so it belongs back on Songs. The stored tab must
      // not have taken the wheel mid-gesture.
      expect(_currentTab(tester), 0);
    });

    testWidgets('tapping the tab you are already on beats a late restore',
        (tester) async {
      final _ManualLibraryTabStore store = _ManualLibraryTabStore();
      await _pump(tester, store);

      // Songs is already selected, so this tap moves no index and the
      // controller listener never runs. It is still the user choosing a tab.
      await tester.tap(find.text('Songs'));
      await tester.pumpAndSettle();

      store.completeWith('artists');
      await tester.pump();
      await tester.pumpAndSettle();

      expect(_currentTab(tester), 0);
      // Keeping the screen on Songs is only half of it: leaving Artists stored
      // would reopen there next launch, on a tab the user had just rejected.
      expect(store.stored, 'songs');
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
