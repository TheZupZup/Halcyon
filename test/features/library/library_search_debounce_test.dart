import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/features/library/library_screen.dart';

import 'fake_music_library_repository.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// The production debounce window. Tests use this constant so a change to the
/// production value is immediately visible here, and timing comments stay
/// accurate without hunting through the test file.
const Duration _debounce = Duration(milliseconds: 300);

/// A duration safely before the debounce fires.
const Duration _beforeDebounce = Duration(milliseconds: 100);

/// A duration safely after the debounce fires.
const Duration _afterDebounce = Duration(milliseconds: 350);

/// Two tracks with names that are easy to distinguish in assertions.
///
/// We use the *artist* name ("Dua") as a sentinel for "the Levitating tile is
/// in the list", because [tester.enterText] puts the query string into the
/// TextField too — searching for the title text alone would find it in two
/// places and break [findsOneWidget]. The artist name only ever appears in the
/// track tile's subtitle.
const List<Track> _tracks = <Track>[
  Track(
    id: '1',
    title: 'Levitating',
    uri: 'file:///1.mp3',
    artistName: 'Dua',
  ),
  Track(id: '2', title: 'Blinding Lights', uri: 'file:///2.mp3'),
];

Future<void> _pumpScreen(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        musicLibraryRepositoryProvider.overrideWithValue(
          FakeMusicLibraryRepository(tracks: _tracks),
        ),
      ],
      child: const MaterialApp(home: LibraryScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('Library search debounce', () {
    // -----------------------------------------------------------------------
    // 1. No immediate filtering
    // -----------------------------------------------------------------------
    testWidgets(
        'typing does not filter the list before the debounce window elapses',
        (tester) async {
      await _pumpScreen(tester);

      // Both tracks are visible.
      expect(find.text('Dua'), findsOneWidget);
      expect(find.text('Blinding Lights'), findsOneWidget);

      // Type a query that would filter out 'Blinding Lights'.
      await tester.enterText(
        find.byKey(const Key('library_search_field')),
        'Levitating',
      );

      // Advance the clock by 100ms — well within the 300ms debounce window.
      await tester.pump(_beforeDebounce);

      // The filter has NOT yet run: both tiles must still be visible.
      expect(
        find.text('Dua'),
        findsOneWidget,
        reason:
            'Levitating tile (artist subtitle) still visible — 100ms < 300ms',
      );
      expect(
        find.text('Blinding Lights'),
        findsOneWidget,
        reason: 'non-matching track must NOT be hidden before debounce fires',
      );
    });

    // -----------------------------------------------------------------------
    // 2. Filtering occurs after 300ms
    // -----------------------------------------------------------------------
    testWidgets('filter applies once 300ms has elapsed', (tester) async {
      await _pumpScreen(tester);

      await tester.enterText(
        find.byKey(const Key('library_search_field')),
        'Levitating',
      );

      // Still within the window — nothing filtered yet.
      await tester.pump(_beforeDebounce);
      expect(find.text('Blinding Lights'), findsOneWidget);

      // Advance to 350ms total — past the 300ms threshold.
      await tester.pump(_afterDebounce - _beforeDebounce);

      // Now the debounce has fired: 'Levitating' matches, 'Blinding Lights' does not.
      expect(
        find.text('Dua'),
        findsOneWidget,
        reason: 'Levitating tile still present — it matches the query',
      );
      expect(
        find.text('Blinding Lights'),
        findsNothing,
        reason: 'non-matching track hidden after 350ms > 300ms debounce',
      );
    });

    // -----------------------------------------------------------------------
    // 3. Rapid typing applies only the final query
    // -----------------------------------------------------------------------
    testWidgets(
        'rapid successive keystrokes within the window collapse to the final '
        'query', (tester) async {
      await _pumpScreen(tester);

      final Finder field = find.byKey(const Key('library_search_field'));

      // Type three intermediate characters, each within the 300ms window of
      // the previous — so every intermediate timer is cancelled before firing.
      await tester.enterText(field, 'L');
      await tester.pump(_beforeDebounce); // 100ms — no fire
      await tester.enterText(field, 'Le');
      await tester.pump(_beforeDebounce); // 100ms — no fire
      await tester.enterText(field, 'Blinding');
      await tester.pump(_beforeDebounce); // 100ms — no fire

      // At this point, 300ms of clock-time has elapsed since the first
      // keystroke but the last timer (started at the 'Blinding' entry) is only
      // 100ms old — the list must still be unfiltered.
      expect(find.text('Dua'), findsOneWidget);
      expect(find.text('Blinding Lights'), findsOneWidget);

      // Advance past the final timer: 100ms already elapsed + 250ms more = 350ms
      // since the last keystroke, which is past the 300ms threshold.
      await tester.pump(_afterDebounce - _beforeDebounce);

      // Only the track matching the final query ('Blinding') survives.
      expect(find.text('Blinding Lights'), findsOneWidget);
      expect(
        find.text('Dua'),
        findsNothing,
        reason:
            'Levitating tile hidden — only the final query is applied after 300ms',
      );
    });

    // -----------------------------------------------------------------------
    // 4. Existing search behavior works
    // -----------------------------------------------------------------------
    testWidgets('search filters Songs tab by title after the debounce fires',
        (tester) async {
      await _pumpScreen(tester);

      await tester.enterText(
        find.byKey(const Key('library_search_field')),
        'levit',
      );
      await tester.pump(_afterDebounce);

      // 'levit' matches 'Levitating' (case-insensitive, via foldText).
      expect(find.text('Dua'), findsOneWidget);
      expect(find.text('Blinding Lights'), findsNothing);
    });

    // -----------------------------------------------------------------------
    // 5. Clear search remains immediate
    // -----------------------------------------------------------------------
    testWidgets('clear button resets the filter immediately without debounce',
        (tester) async {
      await _pumpScreen(tester);

      // Apply a filter first.
      await tester.enterText(
        find.byKey(const Key('library_search_field')),
        'Levitating',
      );
      await tester.pump(_afterDebounce);
      expect(find.text('Blinding Lights'), findsNothing);

      // Tap the clear button — must take effect immediately (no debounce).
      await tester.tap(find.byKey(const Key('library_search_clear')));
      await tester.pump();

      expect(find.text('Dua'), findsOneWidget);
      expect(find.text('Blinding Lights'), findsOneWidget);
    });

    // -----------------------------------------------------------------------
    // 6. Pending debounce is cancelled on disposal
    // -----------------------------------------------------------------------
    testWidgets('pending debounce timer is cancelled when the widget disposes',
        (tester) async {
      await _pumpScreen(tester);

      // Type a query — starts the 300ms timer.
      await tester.enterText(
        find.byKey(const Key('library_search_field')),
        'Levitating',
      );

      // Advance 100ms: timer is pending but has NOT fired.
      await tester.pump(_beforeDebounce);

      // Unmount LibraryScreen — dispose() must cancel the pending timer.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));

      // Advance the fake clock well past the debounce threshold. If the timer
      // were not cancelled, it would fire here and call setState on a disposed
      // State, which the test framework would report as a Flutter error and
      // fail the test.
      await tester.pump(_debounce + const Duration(milliseconds: 100));
      // No assertion needed: reaching this line without a Flutter error proves
      // that dispose() successfully cancelled the timer.
    });

    // -----------------------------------------------------------------------
    // 7. Clear cancels a pending debounce (regression for reviewer edge case)
    // -----------------------------------------------------------------------
    testWidgets(
        'tapping Clear while a debounce is pending prevents the old query '
        'from being restored', (tester) async {
      await _pumpScreen(tester);

      final Finder field = find.byKey(const Key('library_search_field'));
      final Finder clearButton = find.byKey(const Key('library_search_clear'));

      // First, let a query settle so the clear button (X) is visible — the X
      // only renders after LibrarySearchField rebuilds with controller.text
      // non-empty, which happens when the parent setState fires (debounce).
      await tester.enterText(field, 'Levitating');
      await tester.pump(_afterDebounce); // debounce fires → X button appears
      expect(clearButton, findsOneWidget);

      // Now type again immediately — this restarts the 300ms timer.
      // The field text is still non-empty so the X remains visible.
      await tester.enterText(field, 'Blinding');
      await tester.pump(_beforeDebounce); // 100ms — timer still pending

      // The new debounce has not fired yet, so the active query is still 'Levitating'.
      // Therefore, Levitating (Dua) is visible, and Blinding Lights is hidden.
      expect(find.text('Dua'), findsOneWidget);
      expect(find.text('Blinding Lights'), findsNothing,
          reason: 'filter has not updated to Blinding yet at 100ms');

      // User taps Clear before the 300ms window closes.
      await tester.tap(clearButton);
      await tester.pump(); // settle the clear's immediate setState

      // Clear must have taken effect immediately.
      expect(find.text('Dua'), findsOneWidget);
      expect(find.text('Blinding Lights'), findsOneWidget,
          reason: 'clear is immediate — both tracks visible right away');

      // Advance well past 300ms. The cancelled timer must NOT fire and must NOT
      // write 'Blinding' back into _query, which would re-filter the list.
      await tester.pump(_debounce + const Duration(milliseconds: 100));

      expect(find.text('Dua'), findsOneWidget,
          reason: 'Levitating tile still present — query was not restored');
      expect(
        find.text('Blinding Lights'),
        findsOneWidget,
        reason:
            'Blinding Lights still visible — pending debounce did not restore '
            'the stale query after Clear',
      );
    });

    // -----------------------------------------------------------------------
    // 8. Tab change cancels a pending debounce (regression for reviewer edge case)
    // -----------------------------------------------------------------------
    testWidgets(
        'switching tabs while a debounce is pending prevents the old query '
        'from being applied after the tab change', (tester) async {
      await _pumpScreen(tester);

      // Type a query that would filter out Blinding Lights — starts the timer.
      await tester.enterText(
        find.byKey(const Key('library_search_field')),
        'Levitating',
      );

      // Advance 100ms: timer pending, filter has NOT yet run.
      await tester.pump(_beforeDebounce);
      expect(find.text('Blinding Lights'), findsOneWidget,
          reason: 'filter has not run yet at 100ms');

      // Switch to the Albums tab (index 1). This must cancel the pending timer
      // AND clear the query so the stale 'Levitating' filter cannot re-apply.
      await tester.tap(find.text('Albums'));
      await tester.pumpAndSettle();

      // Advance the clock well past 300ms. The cancelled timer must NOT fire.
      await tester.pump(_debounce + const Duration(milliseconds: 100));

      // Switch back to Songs to confirm the query was cleared, not just hidden.
      await tester.tap(find.text('Songs'));
      await tester.pumpAndSettle();

      // Both tracks must be visible — the cancelled timer must not have written
      // 'Levitating' into _query at any point during or after the tab change.
      expect(find.text('Dua'), findsOneWidget,
          reason: 'Levitating tile present — no stale filter applied');
      expect(
        find.text('Blinding Lights'),
        findsOneWidget,
        reason:
            'Blinding Lights visible — tab change cancelled the pending debounce',
      );
    });
  });
}
