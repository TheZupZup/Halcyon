import 'package:flutter/material.dart';

/// Centralized colour palette for Linthra.
///
/// The identity is two colours working together: a vivid **violet** that
/// carries the brand (logo, primary actions, structure) and a warm **orange**
/// accent reserved for things that are *live* — the playing / selected / active
/// states and playback progress. Keeping orange scarce is what makes it read as
/// energy rather than decoration, and it's what separates Linthra from a calm
/// productivity app. Dark mode is the primary experience; the light palette
/// mirrors it so both feel like the same product.
abstract final class AppColors {
  // Brand violet — the primary identity.
  /// The core brand colour: app identity, primary buttons, structural accents.
  static const Color brand = Color(0xFF7C5CFF);

  /// Lighter violet for gradient tops, the logo mark, and hover/emphasis.
  static const Color brandBright = Color(0xFF9C84FF);

  /// Deeper violet for gradient bottoms and pressed states.
  static const Color brandDeep = Color(0xFF5B3FD9);

  /// Low-emphasis violet for tinted containers/indicators on dark surfaces.
  static const Color brandMuted = Color(0xFF463B73);

  // Warm orange — the "live" accent.
  /// The accent: playback / active / selected states, key highlights, progress.
  static const Color accent = Color(0xFFFF9F43);

  /// Lighter orange for gradient tops and the logo mark's warm end.
  static const Color accentBright = Color(0xFFFFB867);

  /// Deeper orange for gradient bottoms and pressed states.
  static const Color accentDeep = Color(0xFFF2861E);

  /// A dark, warm ink for text/icons sitting on an orange fill (e.g. the play
  /// button), where white would wash out against the bright accent.
  static const Color onAccent = Color(0xFF231405);

  /// A dark, warm surface behind selected/active orange content (e.g. a tonal
  /// button or selected chip), readable with [accentBright] as its foreground.
  static const Color accentContainer = Color(0xFF3A2A16);

  // Dark surfaces (primary experience).
  static const Color darkBackground = Color(0xFF111018);
  static const Color darkSurface = Color(0xFF17151F);
  static const Color darkSurfaceHigh = Color(0xFF201D2B);
  static const Color darkSurfaceHighest = Color(0xFF272336);
  static const Color darkOnSurface = Color(0xFFF5F7FA);
  static const Color darkOnSurfaceMuted = Color(0xFF9E9CB0);
  static const Color darkOutline = Color(0xFF322E40);

  // Light surfaces.
  static const Color lightBackground = Color(0xFFF6F5FB);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightSurfaceHigh = Color(0xFFF1EFF8);
  static const Color lightSurfaceHighest = Color(0xFFE9E5F3);
  static const Color lightOnSurface = Color(0xFF1A1820);

  /// Secondary text on the light surfaces.
  ///
  /// Nudged one step darker than the original `0xFF6B6878`, which cleared 4.5:1
  /// on [lightBackground] (5.00:1) but not on [lightSurfaceHighest] — the popup
  /// menu and SnackBar surface — where it landed at 4.38:1. This clears 4.5:1
  /// on all four light surfaces, the tightest being 4.71:1.
  static const Color lightOnSurfaceMuted = Color(0xFF666374);

  /// The border tone for *controls* on the light surfaces — text-field and
  /// outlined-button borders, chip outlines.
  ///
  /// These delimit an interactive control, so they carry WCAG 1.4.11's 3:1
  /// non-text bar: this reaches 3.10:1 on [lightBackground] and 3.37:1 on
  /// [lightSurface]. It is the lightest violet-grey that clears 3:1 on *both*,
  /// so it stays quiet while remaining a real edge. (The previous `0xFFD9D5E6`
  /// managed only 1.33:1 and read as almost no border at all.)
  static const Color lightOutline = Color(0xFF8F88A6);

  /// The separator tone for the light surfaces — list dividers only.
  ///
  /// Dividers here are decorative: the rows they sit between are already
  /// distinguished by their text and spacing, so 1.4.11 does not apply and
  /// pushing them to 3:1 would grid the UI. Kept deliberately softer than
  /// [lightOutline] so a settings list does not turn into a table.
  static const Color lightOutlineVariant = Color(0xFFC7C2D9);

  // Light-mode brand tones.
  //
  // The dark tones above are tuned for dark surfaces and fall well short on the
  // light ones ([brandBright] manages 2.71:1 on [lightBackground]; [accent]
  // 2.04:1), so light mode gets its own set rather than reusing them. Only
  // lightness moves: the light oranges keep [accent]'s exact 29.4° hue at full
  // chroma, and [brandLight] keeps [brand]'s exact 251.8° hue at full chroma,
  // so both modes still read as the same product.

  /// Light-mode [brand]: the identity fill and colour-scheme seed. Same hue and
  /// chroma as [brand], darkened until white-on-it reaches 5.77:1.
  static const Color brandLight = Color(0xFF633DFF);

  /// Light-mode [brandBright]: the identity tone for text, icons, and focus
  /// rings on light surfaces (6.65:1 on [lightSurface]). This is [brandDeep] —
  /// an existing Linthra violet — reused rather than a newly invented one.
  static const Color brandBrightLight = brandDeep;

  /// Light-mode [accent]. Also used as SnackBar action *text*, which is the
  /// binding constraint at 4.58:1 on [lightSurfaceHighest]; this is the
  /// lightest brand-hue orange that clears it.
  static const Color accentLight = Color(0xFFA35000);

  /// Light-mode [accentBright]: the play button's gradient top, and the label
  /// on a selected chip (5.77:1 on [accentContainerLight]).
  static const Color accentBrightLight = Color(0xFF8F4600);

  /// Light-mode [accentDeep]: the play button's gradient bottom.
  static const Color accentDeepLight = Color(0xFF7A3C00);

  /// White reads on the darker light-mode accent (5.67:1); the dark warm ink
  /// [onAccent] uses on the bright orange would not.
  static const Color onAccentLight = Color(0xFFFFFFFF);

  /// A light warm tint behind selected/active accent content, replacing the
  /// dark brown [accentContainer] that would otherwise punch a dark hole in a
  /// light UI.
  static const Color accentContainerLight = Color(0xFFFFE7CE);

  static const Color error = Color(0xFFE5484D);

  /// Light-mode [error]. The shared [error] reaches only 3.91:1 on
  /// [lightSurface] — large-text only — so error copy gets a deeper red on the
  /// light surfaces (6.44:1). Dark mode keeps [error] unchanged.
  static const Color lightError = Color(0xFFB3282E);
}
