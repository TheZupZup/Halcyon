import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/dimens.dart';
import '../../../../core/models/lyric_focus.dart';
import '../../../../core/models/lyrics.dart';
import '../../../../core/models/playback_state.dart';
import '../../player_providers.dart';
import 'lyric_line_tile.dart';
import 'synced_lyric_line.dart';

/// The widest a column of lyrics gets, whatever the screen. Long lines are
/// tiring to read edge-to-edge on a tablet or an unfolded foldable, so the text
/// stays a comfortable measure and centres in the space instead of stretching.
const double _maxLineWidth = 620;

/// Wraps a lyrics list in that measure. Applied once around the scroll view
/// rather than per row, so a long song pays for it exactly once.
Widget _withReadableWidth(Widget child) {
  return Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _maxLineWidth),
      child: child,
    ),
  );
}

/// Plain, untimed lyrics: a calm reading surface.
///
/// Deliberately inert — no highlighting, no auto-scroll, no invented timings,
/// because there is nothing to sync to. What makes it feel considered instead of
/// dumped is typography: generous leading, a capped measure, and room to breathe
/// at both ends.
class PlainLyricsViewport extends StatelessWidget {
  const PlainLyricsViewport({required this.lyrics, super.key});

  final Lyrics lyrics;

  @override
  Widget build(BuildContext context) {
    return _withReadableWidth(
      ListView.builder(
        key: const Key('plain-lyrics'),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.lg,
        ),
        itemCount: lyrics.lines.length,
        itemBuilder: (BuildContext context, int index) => LyricLineTile(
          text: lyrics.lines[index].text,
          emphasis: LyricEmphasis.untimed,
        ),
      ),
    );
  }
}

/// Timed lyrics: the active line held near the middle of the viewport, with the
/// lines around it fading progressively away from it.
///
/// Two things keep this cheap on a low-end phone:
///
///  * The active line index is **listened to, not watched**. The ~4 Hz position
///    stream is reduced to a line index inside a `select`, exactly as before, so
///    a tick that stays within a line costs one scan and nothing else. But the
///    result is pushed into a [ValueNotifier] rather than rebuilding this
///    widget, so even a real line change never rebuilds the list — only the
///    individual [SyncedLyricLine]s whose emphasis moved (see that class).
///  * The only motion is a one-shot scroll when the line changes, plus the
///    per-row style transition. Nothing animates continuously, and both are
///    skipped outright under [MediaQueryData.disableAnimations].
class SyncedLyricsViewport extends ConsumerStatefulWidget {
  const SyncedLyricsViewport({required this.lyrics, super.key});

  final Lyrics lyrics;

  /// How long the one-shot scroll to a newly active line takes.
  ///
  /// Short enough that the line is settled well before the next one starts, and
  /// paired with a curve that eases *in* as well as out: the follow no longer
  /// lurches off the mark the instant a line changes, which was the abrupt part.
  /// It is one animation per line change and nothing in between — the view
  /// schedules no frames while a line is simply playing.
  static const Duration scrollDuration = Duration(milliseconds: 350);

  /// The curve of that scroll. Symmetric easing, so the movement starts and
  /// stops as gently as it travels.
  static const Curve scrollCurve = Curves.easeInOutCubic;

  @override
  ConsumerState<SyncedLyricsViewport> createState() =>
      _SyncedLyricsViewportState();
}

class _SyncedLyricsViewportState extends ConsumerState<SyncedLyricsViewport> {
  /// How long auto-following stands down after the user scrolls by hand, so
  /// reading ahead isn't yanked back to the playing line mid-sentence. It
  /// resumes on the next line change after this, with no timer in between.
  static const Duration _followPause = Duration(seconds: 5);

  /// Where in the viewport the active line settles. Slightly above true centre
  /// reads better: it leaves more of what is coming than of what has gone.
  static const double _activeLineAlignment = 0.42;

  /// Share of the viewport left blank above and below the lyrics, so the first
  /// and last lines can reach the active position like any other.
  static const double _edgePaddingFraction = 0.4;

  /// How many estimate-and-settle passes a jump to an unbuilt row gets before
  /// it gives up. Each pass builds a new band of rows and so measures better
  /// than the last; this only stops a pathological list from walking forever.
  static const int _maxEstimatePasses = 5;

  /// How close an estimate has to land to count as "nowhere left to go".
  static const double _estimateEpsilon = 0.5;

  final ScrollController _scroll = ScrollController();

  /// The active line index the rows subscribe to.
  final ValueNotifier<int> _activeLine = ValueNotifier<int>(-1);

  /// One key per line, used to centre a line once it is laid out.
  List<GlobalKey> _keys = const <GlobalKey>[];

  DateTime? _lastManualScroll;

  /// The blank space the list reserves at each end, cached from layout so an
  /// offset estimate can subtract it. It is padding, not rows.
  double _edgePadding = 0;

  @override
  void initState() {
    super.initState();
    _rebuildKeys();
    _activeLine.value = _activeLineNow();
    // Opening mid-song should land on the current line, not at the top.
    _scheduleCentre(_activeLine.value);
  }

  @override
  void didUpdateWidget(SyncedLyricsViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new track's lyrics: drop the old keys, re-derive the active line, and
    // forget that the user was scrolling the *previous* song by hand.
    if (widget.lyrics != oldWidget.lyrics) {
      _rebuildKeys();
      _lastManualScroll = null;
      _activeLine.value = _activeLineNow();
      if (_scroll.hasClients) _scroll.jumpTo(0);
      _scheduleCentre(_activeLine.value);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    _activeLine.dispose();
    super.dispose();
  }

  void _rebuildKeys() {
    _keys = List<GlobalKey>.generate(
      widget.lyrics.lines.length,
      (_) => GlobalKey(),
    );
  }

  /// The active line for the position playback is at right now.
  ///
  /// Falls back to the controller's synchronous state until the first stream
  /// event arrives, mirroring the rest of the player UI, so opening lyrics
  /// mid-playback highlights immediately instead of starting from -1.
  int _activeLineNow() {
    final PlaybackState state = ref.read(playbackStateProvider).valueOrNull ??
        ref.read(playbackControllerProvider).state;
    return widget.lyrics.activeLineIndex(state.position);
  }

  void _onActiveLineChanged(int next) {
    if (_activeLine.value == next) return;
    _activeLine.value = next;
    _scheduleCentre(next);
  }

  /// Whether auto-following is standing down because the user just scrolled.
  bool get _isFollowPaused {
    final DateTime? last = _lastManualScroll;
    return last != null && DateTime.now().difference(last) < _followPause;
  }

  void _scheduleCentre(int index) {
    if (index < 0 || index >= _keys.length) return;
    if (_isFollowPaused) return;
    // After the frame that lays the new active line out, so the row is measured
    // once it exists. Its emphasis no longer changes its metrics (see
    // LyricLineTile.styleFor), so what is measured here is what the scroll will
    // still be aiming at when it arrives.
    WidgetsBinding.instance.addPostFrameCallback((_) => _centre(index));
  }

  /// Brings the line at [index] to [_activeLineAlignment].
  ///
  /// A row that is currently laid out can be measured directly. A row that
  /// isn't — after a long seek, or a jump from a tapped line, the target can sit
  /// far outside the built window — has no render object for `ensureVisible` to
  /// measure, and that call would silently do nothing. So the scroll is walked
  /// toward it by estimate: each jump builds a new band of rows, which gives a
  /// better estimate for the next pass, until the target itself is laid out and
  /// can be revealed exactly. [pass] bounds that walk so it can always
  /// terminate.
  void _centre(int index, {int pass = 0}) {
    if (!mounted || index < 0 || index >= _keys.length) return;
    if (!_scroll.hasClients) return;

    final BuildContext? lineContext = _keys[index].currentContext;
    if (lineContext != null) {
      unawaited(
        Scrollable.ensureVisible(
          lineContext,
          alignment: _activeLineAlignment,
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : SyncedLyricsViewport.scrollDuration,
          curve: SyncedLyricsViewport.scrollCurve,
        ),
      );
      return;
    }

    if (pass >= _maxEstimatePasses) return;
    final double? estimate = _estimateOffsetFor(index);
    if (estimate == null) return;
    final ScrollPosition position = _scroll.position;
    final double target = estimate.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    // Already as close as this list can get and the row still isn't built:
    // another identical jump would only spin the walk.
    if ((target - position.pixels).abs() < _estimateEpsilon) return;
    _scroll.jumpTo(target);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _centre(index, pass: pass + 1),
    );
  }

  /// The scroll offset that would put row [index] at [_activeLineAlignment],
  /// or null when the list has no geometry to reason about yet.
  ///
  /// Prefers *measured* anchors. Whatever rows are laid out right now report
  /// their real reveal offsets, and the slope between the outermost two is a
  /// per-row extent that already accounts for however those lines wrapped —
  /// far better than assuming every row in the song is the same height.
  ///
  /// Only with nothing measurable does it fall back to dividing the content
  /// evenly, and even then it subtracts the two edge paddings first: they are
  /// blank space, not rows, and counting them would inflate every row and push
  /// the jump further off with each index.
  double? _estimateOffsetFor(int index) {
    if (_keys.isEmpty || !_scroll.hasClients) return null;

    int? firstIndex;
    double? firstOffset;
    int? lastIndex;
    double? lastOffset;
    for (int i = 0; i < _keys.length; i++) {
      final BuildContext? lineContext = _keys[i].currentContext;
      if (lineContext == null) continue;
      final double? offset = _revealOffsetOf(lineContext);
      if (offset == null) continue;
      firstIndex ??= i;
      firstOffset ??= offset;
      lastIndex = i;
      lastOffset = offset;
    }

    if (firstIndex != null && lastIndex != null && lastIndex != firstIndex) {
      final double perRow =
          (lastOffset! - firstOffset!) / (lastIndex - firstIndex);
      return firstOffset + (index - firstIndex) * perRow;
    }
    if (firstIndex != null) {
      // A single anchor still fixes the *origin*; only the slope is assumed.
      return firstOffset! + (index - firstIndex) * _uniformRowExtent();
    }

    final double rowExtent = _uniformRowExtent();
    if (rowExtent <= 0) return null;
    return _edgePadding +
        rowExtent * index +
        rowExtent / 2 -
        _scroll.position.viewportDimension * _activeLineAlignment;
  }

  /// The average height of a row, with the list's blank edge padding removed.
  double _uniformRowExtent() {
    final ScrollPosition position = _scroll.position;
    final double content =
        position.maxScrollExtent + position.viewportDimension;
    final double rows = content - _edgePadding * 2;
    if (rows <= 0 || _keys.isEmpty) return 0;
    return rows / _keys.length;
  }

  /// The scroll offset that would reveal [lineContext]'s row at the active
  /// position — the same measurement `ensureVisible` makes, read directly so it
  /// can serve as an anchor.
  double? _revealOffsetOf(BuildContext lineContext) {
    final RenderObject? box = lineContext.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    final RenderAbstractViewport? viewport =
        RenderAbstractViewport.maybeOf(box);
    if (viewport == null) return null;
    return viewport.getOffsetToReveal(box, _activeLineAlignment).offset;
  }

  @override
  Widget build(BuildContext context) {
    final Lyrics lyrics = widget.lyrics;
    final Duration fallback =
        ref.read(playbackControllerProvider).state.position;

    // Listen rather than watch. The select still collapses the ~4 Hz position
    // stream down to a line index — the battery contract the throttle test
    // pins — but the result lands in a notifier the rows read, so neither this
    // widget nor the list below it rebuilds when the line changes.
    ref.listen<int>(
      playbackStateProvider.select(
        (AsyncValue<PlaybackState> state) => lyrics.activeLineIndex(
          state.valueOrNull?.position ?? fallback,
        ),
      ),
      (int? previous, int next) => _onActiveLineChanged(next),
    );

    return _withReadableWidth(
      LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          // Blank space at both ends so the opening and closing lines can sit
          // where every other active line does.
          final double edgePadding = constraints.maxHeight.isFinite
              ? constraints.maxHeight * _edgePaddingFraction
              : AppSpacing.xl;
          // Cached, not state: a layout constant the offset estimate needs, and
          // writing it changes nothing that would need a rebuild.
          _edgePadding = edgePadding;
          return NotificationListener<ScrollStartNotification>(
            // dragDetails is set only when a finger started the scroll, so the
            // view's own animated centring never counts as the user taking over.
            onNotification: (ScrollStartNotification notification) {
              if (notification.dragDetails != null) {
                _lastManualScroll = DateTime.now();
              }
              return false;
            },
            child: ListView.builder(
              key: const Key('synced-lyrics'),
              controller: _scroll,
              padding: EdgeInsets.fromLTRB(
                AppSpacing.md,
                edgePadding,
                AppSpacing.md,
                edgePadding,
              ),
              itemCount: lyrics.lines.length,
              itemBuilder: (BuildContext context, int index) {
                final LyricLine line = lyrics.lines[index];
                final Duration? start = line.start;
                return KeyedSubtree(
                  key: _keys[index],
                  child: SyncedLyricLine(
                    activeLine: _activeLine,
                    index: index,
                    text: line.text,
                    // Tapping a timed line jumps there through the controller,
                    // so it seeks whichever output is live — local or cast.
                    onSeek: start == null
                        ? null
                        : () =>
                            ref.read(playbackControllerProvider).seek(start),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
