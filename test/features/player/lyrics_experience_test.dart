import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/brand_theme.dart';
import 'package:linthra/app/theme.dart';
import 'package:linthra/core/models/lyrics.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/lyrics_service.dart';
import 'package:linthra/features/player/lyrics_providers.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/player_screen.dart';
import 'package:linthra/features/player/widgets/album_artwork.dart';
import 'package:linthra/features/player/widgets/lyrics/lyric_line_tile.dart';
import 'package:linthra/features/player/widgets/lyrics/lyrics_viewport.dart';
import 'package:linthra/features/player/widgets/lyrics_view.dart';

import '../../support/fake_audio_player.dart';
import 'fake_playback_controller.dart';

/// A lyrics backend returning one canned set for the test track.
class _FakeLyricsService implements LyricsService {
  _FakeLyricsService(this._lyrics);

  final Lyrics? _lyrics;

  @override
  Future<Lyrics?> lyricsFor(Track track) async => _lyrics;
}

const _track = Track(
  id: 'a',
  title: 'Song A',
  uri: 'jellyfin:a',
  artistName: 'Artist A',
  albumName: 'Album A',
);

/// Enough lines that the fade band (active ± 2) doesn't cover the whole song,
/// so "distant" is genuinely reachable.
const _synced = Lyrics(lines: <LyricLine>[
  LyricLine(text: 'line one', start: Duration.zero),
  LyricLine(text: 'line two', start: Duration(seconds: 10)),
  LyricLine(text: 'line three', start: Duration(seconds: 20)),
  LyricLine(text: 'line four', start: Duration(seconds: 30)),
  LyricLine(text: 'line five', start: Duration(seconds: 40)),
  LyricLine(text: 'line six', start: Duration(seconds: 50)),
  LyricLine(text: 'line seven', start: Duration(seconds: 60)),
]);

/// A timed set with an interior *timestamped blank* line — what
/// `LyricsTextParser` produces for a bare `[00:10.00]` tag in an `.lrc`, kept
/// for stanza rhythm.
const _syncedWithGap = Lyrics(lines: <LyricLine>[
  LyricLine(text: 'before the gap', start: Duration.zero),
  LyricLine(text: '', start: Duration(seconds: 10)),
  LyricLine(text: 'after the gap', start: Duration(seconds: 20)),
]);

/// A long song whose lines wrap to very different heights, so no single
/// per-row extent describes the list. Line `i` starts at `i` seconds.
Lyrics _unevenLyrics({int count = 60}) {
  return Lyrics(
    lines: List<LyricLine>.generate(count, (int i) {
      // Every third line is a long one that wraps over several rows.
      final String text = i % 3 == 0
          ? 'line $i ${'and it carries on well past the end of the line ' * 4}'
          : 'line $i';
      return LyricLine(text: text, start: Duration(seconds: i));
    }),
  );
}

const _plain = Lyrics(lines: <LyricLine>[
  LyricLine(text: 'plain one'),
  LyricLine(text: 'plain two'),
  LyricLine(text: 'plain three'),
]);

PlaybackState _playingAt(Duration position) => PlaybackState(
      status: PlaybackStatus.playing,
      currentTrack: _track,
      position: position,
      duration: const Duration(seconds: 90),
    );

/// The style the synced view applied to [text]: the [AnimatedDefaultTextStyle]
/// that *directly* wraps this line's [Text] (Material wraps plenty of others).
AnimatedDefaultTextStyle _wrapperOf(WidgetTester tester, String text) {
  final Iterable<AnimatedDefaultTextStyle> candidates =
      tester.widgetList<AnimatedDefaultTextStyle>(
    find.ancestor(
      of: find.text(text),
      matching: find.byType(AnimatedDefaultTextStyle),
    ),
  );
  for (final AnimatedDefaultTextStyle wrapper in candidates) {
    final Widget child = wrapper.child;
    if (child is Text && child.data == text) return wrapper;
  }
  return candidates.first;
}

TextStyle _styleOf(WidgetTester tester, String text) =>
    _wrapperOf(tester, text).style;

double _opacityOf(WidgetTester tester, String text) =>
    _styleOf(tester, text).color!.a;

/// The whole row [text] is rendered in.
Finder _tileOf(String text) => find.ancestor(
      of: find.text(text),
      matching: find.byType(LyricLineTile),
    );

/// How visible that row's accent marker is — the non-colour, non-typographic
/// cue for the active line.
double _markerOpacityOf(WidgetTester tester, String text) {
  return tester
      .widget<AnimatedOpacity>(
        find.descendant(
          of: _tileOf(text),
          matching: find.byType(AnimatedOpacity),
        ),
      )
      .opacity;
}

/// Gives the test a tall window, so a whole song's worth of lines is on screen
/// at once (and so Now Playing's fixed chrome fits at a large text scale).
void _useTallWindow(WidgetTester tester, {double height = 1600}) {
  tester.view.physicalSize = Size(900, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _pumpPlayer(
  WidgetTester tester, {
  required FakePlaybackController controller,
  Lyrics? lyrics,
  bool disableAnimations = false,
  TextScaler textScaler = TextScaler.noScaling,
  ThemeData? theme,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        playbackControllerProvider.overrideWithValue(controller),
        lyricsServiceProvider.overrideWithValue(_FakeLyricsService(lyrics)),
      ],
      child: MaterialApp(
        theme: theme,
        home: Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: disableAnimations,
              textScaler: textScaler,
            ),
            child: const PlayerScreen(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openLyrics(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Lyrics'));
  await tester.pumpAndSettle();
}

void main() {
  group('lyrics-focused mode', () {
    testWidgets('the lyrics button swaps the artwork for the lyrics',
        (tester) async {
      await _pumpPlayer(
        tester,
        controller: FakePlaybackController(initial: _playingAt(Duration.zero)),
        lyrics: _synced,
      );

      // Artwork owns the stage until lyrics are asked for.
      expect(find.byType(AlbumArtwork), findsOneWidget);
      expect(find.byKey(const Key('synced-lyrics')), findsNothing);

      await _openLyrics(tester);

      expect(find.byKey(const Key('synced-lyrics')), findsOneWidget);
      expect(find.byType(AlbumArtwork), findsNothing);
    });

    testWidgets('playback controls stay reachable while lyrics are showing',
        (tester) async {
      final controller =
          FakePlaybackController(initial: _playingAt(Duration.zero));
      await _pumpPlayer(tester, controller: controller, lyrics: _synced);
      await _openLyrics(tester);

      // The whole transport row is still on screen, and still drives playback.
      expect(find.byTooltip('Pause'), findsOneWidget);
      expect(find.byTooltip('Next'), findsOneWidget);
      expect(find.byTooltip('Previous'), findsOneWidget);
      await tester.tap(find.byTooltip('Pause'));
      expect(controller.pauseCount, 1);

      // And what is playing is still named, in the compact line.
      expect(find.text('Song A'), findsOneWidget);
      expect(find.text('Artist A'), findsOneWidget);
    });

    testWidgets('the toggle returns the artwork', (tester) async {
      await _pumpPlayer(
        tester,
        controller: FakePlaybackController(initial: _playingAt(Duration.zero)),
        lyrics: _synced,
      );
      await _openLyrics(tester);
      expect(find.byKey(const Key('synced-lyrics')), findsOneWidget);

      await tester.tap(find.byTooltip('Hide lyrics'));
      await tester.pumpAndSettle();

      expect(find.byType(AlbumArtwork), findsOneWidget);
      expect(find.byKey(const Key('synced-lyrics')), findsNothing);
    });
  });

  group('synced lyrics presentation', () {
    testWidgets('the active line is visually dominant', (tester) async {
      await _pumpPlayer(
        tester,
        controller: FakePlaybackController(
          initial: _playingAt(const Duration(seconds: 12)),
        ),
        lyrics: _synced,
      );
      await _openLyrics(tester);

      // 12s lands on "line two" (10s..20s).
      final TextStyle active = _styleOf(tester, 'line two');
      final TextStyle neighbour = _styleOf(tester, 'line one');

      expect(active.fontWeight, FontWeight.w700);
      expect(neighbour.fontWeight, FontWeight.w500);
      // Heavier, fully opaque, and a different colour — dominance is carried by
      // weight too, never by colour alone.
      expect(active.color!.a, 1.0);
      expect(active.color, isNot(neighbour.color));
      // …and by the accent marker beside it, the cue that survives a reader who
      // can see neither the weight nor the colour.
      expect(_markerOpacityOf(tester, 'line two'), 1.0);
      expect(_markerOpacityOf(tester, 'line one'), 0.0);
    });

    testWidgets('emphasis never changes a timed line\'s metrics',
        (tester) async {
      _useTallWindow(tester);
      await _pumpPlayer(
        tester,
        controller: FakePlaybackController(
          initial: _playingAt(const Duration(seconds: 12)),
        ),
        lyrics: _synced,
      );
      await _openLyrics(tester);

      // Auto-follow animates the list while the rows restyle, so a size or
      // leading that moved with emphasis would change row geometry underneath
      // the scroll. Every timed state has to lay out identically.
      final TextStyle active = _styleOf(tester, 'line two');
      for (final String other in <String>[
        'line one', // adjacent
        'line four', // near
        'line five', // distant
      ]) {
        final TextStyle style = _styleOf(tester, other);
        expect(style.fontSize, active.fontSize, reason: '$other font size');
        expect(style.height, active.height, reason: '$other line height');
        expect(
          style.letterSpacing,
          active.letterSpacing,
          reason: '$other letter spacing',
        );
      }
    });

    testWidgets('a line keeps its exact height as it becomes active',
        (tester) async {
      _useTallWindow(tester);
      final controller = FakePlaybackController(
        initial: _playingAt(const Duration(seconds: 12)),
      );
      await _pumpPlayer(tester, controller: controller, lyrics: _synced);
      await _openLyrics(tester);

      // Measured while it is merely adjacent…
      final Size text = tester.getSize(find.text('line three'));
      final Size row = tester.getSize(_tileOf('line three'));

      controller.emit(_playingAt(const Duration(seconds: 22)));
      await tester.pumpAndSettle();
      expect(_styleOf(tester, 'line three').fontWeight, FontWeight.w700);

      // …and unchanged now that it is the line playing. The whole row, marker
      // gutter and all, keeps exactly the space it had.
      expect(tester.getSize(find.text('line three')), text);
      expect(tester.getSize(_tileOf('line three')), row);
    });

    testWidgets('auto-follow is one short transition, not a running animation',
        (tester) async {
      final controller = FakePlaybackController(
        initial: _playingAt(const Duration(seconds: 12)),
      );
      await _pumpPlayer(tester, controller: controller, lyrics: _synced);
      await _openLyrics(tester);

      // Short enough to be over before the next line, eased at both ends so it
      // neither lurches off the mark nor arrives abruptly.
      expect(
        SyncedLyricsViewport.scrollDuration.inMilliseconds,
        inInclusiveRange(340, 360),
      );
      expect(SyncedLyricsViewport.scrollCurve, Curves.easeInOutCubic);

      final ScrollableState list = tester.state<ScrollableState>(
        find.descendant(
          of: find.byKey(const Key('synced-lyrics')),
          matching: find.byType(Scrollable),
        ),
      );
      final double start = list.position.pixels;

      controller.emit(_playingAt(const Duration(seconds: 22)));
      // The change reaches the viewport through the position stream and is
      // measured in a post-frame callback, so the scroll starts a few frames
      // later rather than on the emit itself.
      double midway = start;
      for (int i = 0; i < 5 && midway == start; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        midway = list.position.pixels;
      }

      // Part way there: the follow travels, it does not jump.
      expect(midway, greaterThan(start), reason: 'auto-follow never started');

      // And it arrives within its own duration.
      await tester.pump(SyncedLyricsViewport.scrollDuration);
      final double settled = list.position.pixels;
      expect(settled, greaterThan(midway));

      // Nothing is left running: a line that is simply playing costs no frames.
      await tester.pumpAndSettle();
      expect(list.position.pixels, settled);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('surrounding lines fade progressively, not uniformly',
        (tester) async {
      // Tall enough that the whole fade band is built and measurable at once.
      _useTallWindow(tester);
      await _pumpPlayer(
        tester,
        controller: FakePlaybackController(
          initial: _playingAt(const Duration(seconds: 12)),
        ),
        lyrics: _synced,
      );
      await _openLyrics(tester);

      // "line two" is active, so three/four/five step further away from it.
      final double adjacent = _opacityOf(tester, 'line three');
      final double near = _opacityOf(tester, 'line four');
      final double distant = _opacityOf(tester, 'line five');

      expect(_opacityOf(tester, 'line two'), greaterThan(adjacent));
      expect(adjacent, greaterThan(near));
      expect(near, greaterThan(distant));
    });

    testWidgets('the highlight follows the position across a line boundary',
        (tester) async {
      final controller = FakePlaybackController(
        initial: _playingAt(const Duration(seconds: 12)),
      );
      await _pumpPlayer(tester, controller: controller, lyrics: _synced);
      await _openLyrics(tester);
      expect(_styleOf(tester, 'line two').fontWeight, FontWeight.w700);

      controller.emit(_playingAt(const Duration(seconds: 22)));
      await tester.pumpAndSettle();

      expect(_styleOf(tester, 'line three').fontWeight, FontWeight.w700);
      expect(_styleOf(tester, 'line two').fontWeight, FontWeight.w500);
    });

    testWidgets('the active line is kept near the middle of the viewport',
        (tester) async {
      final controller =
          FakePlaybackController(initial: _playingAt(Duration.zero));
      await _pumpPlayer(tester, controller: controller, lyrics: _synced);
      await _openLyrics(tester);

      final Rect viewport = tester.getRect(
        find.byKey(const Key('synced-lyrics')),
      );

      // Walk the song and check the active line never drifts out toward an
      // edge — the whole point of the auto-follow.
      for (final ({int seconds, String text}) step
          in <({int seconds, String text})>[
        (seconds: 20, text: 'line three'),
        (seconds: 40, text: 'line five'),
        (seconds: 60, text: 'line seven'),
      ]) {
        controller.emit(_playingAt(Duration(seconds: step.seconds)));
        await tester.pumpAndSettle();

        final Rect line = tester.getRect(find.text(step.text));
        expect(
          line.center.dy,
          greaterThan(viewport.top + viewport.height * 0.15),
          reason: '${step.text} drifted off the top of the viewport',
        );
        expect(
          line.center.dy,
          lessThan(viewport.bottom - viewport.height * 0.15),
          reason: '${step.text} drifted off the bottom of the viewport',
        );
      }
    });
  });

  group('following across a long seek', () {
    testWidgets('a jump far down an uneven song still lands the active line',
        (tester) async {
      // Uneven wrapped heights mean a single averaged row extent describes the
      // list badly; the target row also starts far outside the built window, so
      // ensureVisible alone has nothing to measure.
      final Lyrics lyrics = _unevenLyrics();
      final controller =
          FakePlaybackController(initial: _playingAt(Duration.zero));
      await _pumpPlayer(tester, controller: controller, lyrics: lyrics);
      await _openLyrics(tester);

      const String target = 'line 52';
      expect(find.textContaining(target), findsNothing);

      controller.emit(_playingAt(const Duration(seconds: 52)));
      await tester.pumpAndSettle();

      // Built, on screen, and actually near the active position — not merely
      // scrolled somewhere in its general direction.
      final Finder line = find.textContaining(target);
      expect(line, findsOneWidget);
      final Rect viewport =
          tester.getRect(find.byKey(const Key('synced-lyrics')));
      final Rect rect = tester.getRect(line);
      expect(rect.center.dy, greaterThan(viewport.top));
      expect(rect.center.dy, lessThan(viewport.bottom));
    });

    testWidgets('jumping back up to the opening line lands too',
        (tester) async {
      final Lyrics lyrics = _unevenLyrics();
      final controller = FakePlaybackController(
        initial: _playingAt(const Duration(seconds: 52)),
      );
      await _pumpPlayer(tester, controller: controller, lyrics: lyrics);
      await _openLyrics(tester);

      controller.emit(_playingAt(Duration.zero));
      await tester.pumpAndSettle();

      final Finder line = find.textContaining('line 0 ');
      expect(line, findsOneWidget);
      final Rect viewport =
          tester.getRect(find.byKey(const Key('synced-lyrics')));
      final Rect rect = tester.getRect(line);
      expect(rect.center.dy, greaterThan(viewport.top));
      expect(rect.center.dy, lessThan(viewport.bottom));
    });
  });

  group('seeking from a lyric line', () {
    testWidgets('tapping a timed line seeks through the PlaybackController',
        (tester) async {
      final controller =
          FakePlaybackController(initial: _playingAt(Duration.zero));
      await _pumpPlayer(tester, controller: controller, lyrics: _synced);
      await _openLyrics(tester);

      await tester.tap(find.text('line three'));
      await tester.pumpAndSettle();

      // Routed through the controller — never straight at the audio engine —
      // so it seeks whichever output is live.
      expect(controller.seeks, <Duration>[const Duration(seconds: 20)]);
    });

    testWidgets('a seekable line is a comfortably large touch target',
        (tester) async {
      await _pumpPlayer(
        tester,
        controller: FakePlaybackController(initial: _playingAt(Duration.zero)),
        lyrics: _synced,
      );
      await _openLyrics(tester);

      final Size target = tester.getSize(
        find.ancestor(
          of: find.text('line three'),
          matching: find.byType(InkWell),
        ),
      );
      expect(target.height, greaterThanOrEqualTo(48.0));
    });

    testWidgets('a timestamped blank line stays pure spacing', (tester) async {
      await _pumpPlayer(
        tester,
        controller: FakePlaybackController(
          // 12s: the blank line at 10s is the active one.
          initial: _playingAt(const Duration(seconds: 12)),
        ),
        lyrics: _syncedWithGap,
      );
      await _openLyrics(tester);

      final Finder blank = find.byWidgetPredicate(
        (Widget w) => w is LyricLineTile && w.text.trim().isEmpty,
      );
      expect(blank, findsOneWidget);

      // No tap target: seeking to a stanza gap would offer an unlabelled button.
      expect(
        find.descendant(of: blank, matching: find.byType(InkWell)),
        findsNothing,
      );
      // And nothing for a screen reader to land on.
      expect(
        find.descendant(of: blank, matching: find.byType(ExcludeSemantics)),
        findsOneWidget,
      );
      // Even though it is the active line, no accent pill floats beside the
      // empty row.
      final Iterable<AnimatedOpacity> markers =
          tester.widgetList<AnimatedOpacity>(
        find.descendant(of: blank, matching: find.byType(AnimatedOpacity)),
      );
      expect(markers, isNotEmpty);
      for (final AnimatedOpacity marker in markers) {
        expect(marker.opacity, 0.0);
      }

      // The real lines around it are still perfectly seekable.
      expect(
        find.descendant(
          of: find.ancestor(
            of: find.text('after the gap'),
            matching: find.byType(LyricLineTile),
          ),
          matching: find.byType(InkWell),
        ),
        findsOneWidget,
      );
    });

    testWidgets('plain lyrics are not seekable', (tester) async {
      final controller =
          FakePlaybackController(initial: _playingAt(Duration.zero));
      await _pumpPlayer(tester, controller: controller, lyrics: _plain);
      await _openLyrics(tester);

      await tester.tap(find.text('plain two'));
      await tester.pumpAndSettle();

      // No timestamps means nothing honest to seek to.
      expect(controller.seeks, isEmpty);
    });
  });

  group('unsynced and missing lyrics', () {
    testWidgets('plain lyrics render with no highlighting at all',
        (tester) async {
      await _pumpPlayer(
        tester,
        controller: FakePlaybackController(
          initial: _playingAt(const Duration(seconds: 12)),
        ),
        lyrics: _plain,
      );
      await _openLyrics(tester);

      expect(find.byKey(const Key('plain-lyrics')), findsOneWidget);
      expect(find.byKey(const Key('synced-lyrics')), findsNothing);

      // Every line reads identically: no fake "current line" despite playback
      // being well underway.
      final TextStyle first = _styleOf(tester, 'plain one');
      expect(_styleOf(tester, 'plain two'), first);
      expect(_styleOf(tester, 'plain three'), first);
    });

    testWidgets('plain lyrics keep a readable measure on a wide screen',
        (tester) async {
      tester.view.physicalSize = const Size(2400, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await _pumpPlayer(
        tester,
        controller: FakePlaybackController(initial: _playingAt(Duration.zero)),
        lyrics: _plain,
      );
      await _openLyrics(tester);

      final Size list = tester.getSize(find.byKey(const Key('plain-lyrics')));
      expect(list.width, lessThanOrEqualTo(620.0));
    });

    testWidgets('a track with no lyrics shows the calm empty state',
        (tester) async {
      await _pumpPlayer(
        tester,
        controller: FakePlaybackController(initial: _playingAt(Duration.zero)),
        lyrics: null,
      );
      await _openLyrics(tester);

      expect(find.text('No lyrics available yet.'), findsOneWidget);
      expect(find.byKey(const Key('synced-lyrics')), findsNothing);
      expect(find.byKey(const Key('plain-lyrics')), findsNothing);
    });

    testWidgets('an empty lyrics document shows the empty state too',
        (tester) async {
      await _pumpPlayer(
        tester,
        controller: FakePlaybackController(initial: _playingAt(Duration.zero)),
        lyrics: const Lyrics(lines: <LyricLine>[]),
      );
      await _openLyrics(tester);

      expect(find.text('No lyrics available yet.'), findsOneWidget);
    });
  });

  group('accessibility', () {
    testWidgets('reduced motion removes the line transition and the scroll',
        (tester) async {
      final controller = FakePlaybackController(
        initial: _playingAt(const Duration(seconds: 12)),
      );
      await _pumpPlayer(
        tester,
        controller: controller,
        lyrics: _synced,
        disableAnimations: true,
      );
      await _openLyrics(tester);

      // Each lyric line's own style wrapper — not Material's internal ones,
      // which carry their own theme-change duration and aren't ours to assert.
      for (final String text in <String>[
        'line one',
        'line two',
        'line three'
      ]) {
        expect(_wrapperOf(tester, text).duration, Duration.zero);
      }
      // The accent marker fades on the same (zero) schedule.
      final Iterable<AnimatedOpacity> markers =
          tester.widgetList<AnimatedOpacity>(
        find.descendant(
          of: find.byType(LyricLineTile),
          matching: find.byType(AnimatedOpacity),
        ),
      );
      expect(markers, isNotEmpty);
      for (final AnimatedOpacity marker in markers) {
        expect(marker.duration, Duration.zero);
      }

      // Crossing a boundary still lands the highlight, and lands it *whole*:
      // one frame to deliver the position and one to rebuild the rows, with no
      // interpolation left in flight. Mid-animation this would still read w500.
      controller.emit(_playingAt(const Duration(seconds: 22)));
      await tester.pump();
      await tester.pump();
      expect(_styleOf(tester, 'line three').fontWeight, FontWeight.w700);
    });

    testWidgets('the active line reports itself as selected to screen readers',
        (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();

      await _pumpPlayer(
        tester,
        controller: FakePlaybackController(
          initial: _playingAt(const Duration(seconds: 12)),
        ),
        lyrics: _synced,
      );
      await _openLyrics(tester);

      // Emphasis must not be colour-only: the active line is announced as
      // selected, and every timed line as something you can act on. Every timed
      // line carries selected *state* — the set behaves like a tab bar, so a
      // screen reader can tell "not the current line" from "not selectable".
      expect(
        tester.getSemantics(find.text('line two')),
        matchesSemantics(
          label: 'line two',
          hint: 'Play from this line',
          hasSelectedState: true,
          isSelected: true,
          isButton: true,
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );
      expect(
        tester.getSemantics(find.text('line three')),
        matchesSemantics(
          label: 'line three',
          hint: 'Play from this line',
          hasSelectedState: true,
          isButton: true,
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );

      // Disposed in the body: the framework verifies outstanding handles before
      // tearDowns run.
      handle.dispose();
    });

    testWidgets('lyrics stay readable and unclipped at a large text scale',
        (tester) async {
      await _pumpPlayer(
        tester,
        controller: FakePlaybackController(
          initial: _playingAt(const Duration(seconds: 12)),
        ),
        lyrics: _synced,
        textScaler: const TextScaler.linear(2.0),
      );
      await _openLyrics(tester);

      // No overflow anywhere in the tree (the harness turns one into a failure
      // via the exception below), and the lines really did grow.
      expect(tester.takeException(), isNull);
      expect(find.text('line two'), findsOneWidget);

      final RenderBox line = tester.renderObject<RenderBox>(
        find.text('line two'),
      );
      expect(line.size.height, greaterThan(30));
    });

    testWidgets('the empty state survives a stage squeezed to almost nothing',
        (tester) async {
      // Now Playing's fixed controls can leave the stage shorter than the
      // placeholder's own padding — a short landscape window, or a large text
      // scale. Asking for a negative minimum height is not valid
      // BoxConstraints and throws during layout, so the floor has to hold.
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            linuxAudioPlayerProvider.overrideWithValue(FakeAudioPlayer()),
            lyricsServiceProvider.overrideWithValue(_FakeLyricsService(null)),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(height: 8, width: 300, child: LyricsView()),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('the empty state scrolls rather than clipping at a huge scale',
        (tester) async {
      // Now Playing's fixed chrome (metadata, transport, actions) does not
      // itself fit an 800x600 window at 3x — that is true of the artwork mode
      // too and is out of scope here. The window is sized so the panel, not the
      // chrome, is what this test measures.
      _useTallWindow(tester);
      await _pumpPlayer(
        tester,
        controller: FakePlaybackController(initial: _playingAt(Duration.zero)),
        lyrics: null,
        textScaler: const TextScaler.linear(3.0),
      );
      await _openLyrics(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('No lyrics available yet.'), findsOneWidget);
    });
  });

  group('theming', () {
    for (final ({String name, ThemeData theme}) variant
        in <({String name, ThemeData theme})>[
      (name: 'dark', theme: AppTheme.dark(BrandPalettes.classic)),
      (name: 'light', theme: AppTheme.light(BrandPalettes.classicLight)),
    ]) {
      testWidgets('lyrics take their colours from the ${variant.name} scheme',
          (tester) async {
        await _pumpPlayer(
          tester,
          controller: FakePlaybackController(
            initial: _playingAt(const Duration(seconds: 12)),
          ),
          lyrics: _synced,
          theme: variant.theme,
        );
        await _openLyrics(tester);

        final ColorScheme colors = variant.theme.colorScheme;
        final TextStyle active = _styleOf(tester, 'line two');

        // The dominant line is the scheme's own foreground at full strength,
        // so it reads over any cover in either brightness.
        expect(active.color, colors.onSurface);
        // And the receding lines are that same foreground, just quieter — no
        // hard-coded greys.
        final Color faded = _styleOf(tester, 'line one').color!;
        expect(faded.a, lessThan(1.0));
        expect(
          faded.withValues(alpha: 1.0),
          colors.onSurface.withValues(alpha: 1.0),
        );
      });
    }

    testWidgets('the active-line marker uses the brand accent', (tester) async {
      final ThemeData theme = AppTheme.dark(BrandPalettes.classic);
      await _pumpPlayer(
        tester,
        controller: FakePlaybackController(
          initial: _playingAt(const Duration(seconds: 12)),
        ),
        lyrics: _synced,
        theme: theme,
      );
      await _openLyrics(tester);

      // The redundant, non-colour-only cue next to the active line is drawn in
      // the same accent the progress line and play button use.
      final Iterable<Container> markers = tester.widgetList<Container>(
        find.descendant(
          of: find.byType(LyricLineTile),
          matching: find.byType(Container),
        ),
      );
      expect(
        markers.map((Container c) => (c.decoration as BoxDecoration?)?.color),
        contains(theme.colorScheme.secondary),
      );
    });
  });
}
