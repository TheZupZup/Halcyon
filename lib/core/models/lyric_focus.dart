/// How much visual weight a lyric line carries relative to the line playing
/// right now.
///
/// This is the *whole* of the "which line is emphasised how much" rule, kept as
/// plain data so it can be reasoned about (and tested) without a widget tree, a
/// painter, or a playback controller. Presentation widgets map an emphasis onto
/// type, colour, and opacity; they never derive it themselves.
enum LyricEmphasis {
  /// The line playing right now — the one the eye should land on.
  active,

  /// Immediately before or after the active line: clearly readable, plainly
  /// secondary.
  adjacent,

  /// Two lines out. Still legible, visibly receded.
  near,

  /// Everything further away, fading into the backdrop.
  distant,

  /// Lyrics with no timing at all. Every line reads the same, because there is
  /// no honest way to say which one is playing.
  untimed,
}

/// The emphasis the line at [index] should carry when [activeIndex] is playing.
///
/// [activeIndex] is exactly what `Lyrics.activeLineIndex` returns, including its
/// `-1` for "no line has started yet" (an instrumental intro, or plain lyrics).
/// In that case every line comes back as [LyricEmphasis.near]: uniformly calm,
/// with nothing highlighted, rather than guessing at a line that isn't playing.
///
/// The fade is symmetric — a line two ahead recedes as much as a line two back.
/// Distance is the only input, so this stays a pure function of the two indices.
LyricEmphasis lyricEmphasisFor({
  required int index,
  required int activeIndex,
}) {
  if (activeIndex < 0) return LyricEmphasis.near;
  return switch ((index - activeIndex).abs()) {
    0 => LyricEmphasis.active,
    1 => LyricEmphasis.adjacent,
    2 => LyricEmphasis.near,
    _ => LyricEmphasis.distant,
  };
}
