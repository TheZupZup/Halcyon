import 'package:flutter/material.dart';

import 'colors.dart';

/// The accent/brand colours one branding variant paints the app with.
///
/// Selecting an [AppIconVariant] does more than restyle the mark and the
/// launcher icon: it also retints the app's accent (and, for the neutral
/// variants, its brand colour) so the picker reads as a complete visual theme
/// selector. A [BrandPalette] is the small, data-only seam that carries those
/// colours; [BrandPalettes] maps each variant id to one (falling back to
/// [BrandPalettes.classic] for an unknown/absent id, exactly like
/// `AppIconVariants.byId`), and `AppTheme` threads the chosen palette through
/// the whole [ThemeData] so no screen has to know about variants.
///
/// Keeping this as plain `const` data — no images, no extra assets — means the
/// whole registry ships in every build and is trivially unit-testable, mirroring
/// the `AppIconVariant` catalog it parallels.
///
/// Roles — black-first: surfaces stay dark and colour carries identity and
/// energy. Classic pairs the Linthra purple identity with a warm orange accent
/// (black + orange + purple); the neutral themes (Neon neon-blue, Gold gold,
/// Black & White white) stay a single accent that fills both roles:
///  - [primary]/[primaryBright]/[onPrimary] → the colour-scheme seed and the
///    identity tone for selected navigation, text buttons, input focus, and
///    selected rows (Linthra purple for Classic). [primaryBright] is the
///    accessible-on-dark tone.
///  - [accent]/[onAccent]        → `colorScheme.secondary`/`onSecondary` — the
///    energy accent on filled call-to-action buttons, progress, sliders, the
///    play button, and small emphasis (warm orange for Classic). Equal to
///    [primary] for the single-accent neutral themes.
///  - [accentBright]             → `colorScheme.onSecondaryContainer` and the
///    play button's gradient top (via [LinthraAccents]).
///  - [accentDeep]               → the play button's gradient bottom (via
///    [LinthraAccents]); it has no Material colour-scheme slot of its own.
///  - [accentContainer]          → `colorScheme.secondaryContainer`.
@immutable
class BrandPalette {
  const BrandPalette({
    required this.id,
    required this.primary,
    required this.onPrimary,
    required this.primaryBright,
    required this.accent,
    required this.accentBright,
    required this.accentDeep,
    required this.onAccent,
    required this.accentContainer,
  });

  /// The matching [AppIconVariant.id]. Never shown to users.
  final String id;

  /// The theme's identity colour (Linthra purple for Classic): the colour-scheme
  /// seed and the tint behind selected navigation and selected rows. Equal to
  /// [accent] for the single-accent neutral themes.
  final Color primary;

  /// Text/icon colour on a [primary] fill (and the selected switch thumb).
  final Color onPrimary;

  /// The identity tone for text/icons/borders — selected navigation, text
  /// buttons, selected rows, input focus — where [primary] itself can fall
  /// short of the text-contrast bar.
  ///
  /// "Bright" is relative to the surfaces it sits on: a *lighter* take on
  /// [primary] for the dark palettes, and a *deeper* one for the light
  /// palettes. Either way it is the tone that carries small text safely.
  final Color primaryBright;

  /// The energy accent (warm orange for Classic) on filled call-to-action
  /// buttons, progress, sliders, the play button, and small emphasis.
  final Color accent;

  /// Lighter accent for the play button's gradient top and tonal foregrounds.
  final Color accentBright;

  /// Deeper accent for the play button's gradient bottom / pressed states.
  final Color accentDeep;

  /// Text/icon colour on an [accent] fill (e.g. the play button glyph).
  final Color onAccent;

  /// A muted surface behind selected/active accent content (selected chips).
  final Color accentContainer;
}

/// The two accent tones Material's [ColorScheme] has no slot for, carried on the
/// [ThemeData] so call sites can read them reactively via
/// `Theme.of(context).extension<LinthraAccents>()`.
///
/// [accent] and [onAccent] already live in the scheme (`secondary`/
/// `onSecondary`), so this extension stays minimal: it only adds the play
/// button's gradient ends. Implementing [lerp] lets a theme switch animate
/// smoothly like any other [ThemeData] change.
@immutable
class LinthraAccents extends ThemeExtension<LinthraAccents> {
  const LinthraAccents({
    required this.accentBright,
    required this.accentDeep,
  });

  /// The play button's gradient top (the palette's [BrandPalette.accentBright]).
  final Color accentBright;

  /// The play button's gradient bottom (the palette's [BrandPalette.accentDeep]).
  final Color accentDeep;

  @override
  LinthraAccents copyWith({Color? accentBright, Color? accentDeep}) {
    return LinthraAccents(
      accentBright: accentBright ?? this.accentBright,
      accentDeep: accentDeep ?? this.accentDeep,
    );
  }

  @override
  LinthraAccents lerp(ThemeExtension<LinthraAccents>? other, double t) {
    if (other is! LinthraAccents) {
      return this;
    }
    return LinthraAccents(
      accentBright: Color.lerp(accentBright, other.accentBright, t)!,
      accentDeep: Color.lerp(accentDeep, other.accentDeep, t)!,
    );
  }
}

/// The built-in brand palettes, one per [AppIconVariant], and the resolver the
/// theme reads them through.
///
/// [classic] is the full Linthra identity — black surfaces, a warm orange
/// energy accent, and a Linthra-purple [primary] for the identity details
/// (selected navigation, text buttons, input focus, selected rows). The neutral
/// themes are a single accent with no second hue: [neon] neon cyan/blue, [gold]
/// gold, and [blackWhite] pure black/white, each setting [primary] equal to its
/// [accent] so the whole UI reads as one accent on black. [primaryBright] is the
/// tone that carries identity text/icons at the contrast bar for its mode.
///
/// Each variant has both a dark palette (in [all]) and a light one (in
/// [allLight], suffixed `Light`); [byId] picks between them by brightness.
/// Error/destructive colours are never themed by variant, though the light
/// themes do use a deeper red than the dark ones — see [AppColors.lightError].
abstract final class BrandPalettes {
  /// The default — black + orange + purple: a warm orange energy accent with a
  /// Linthra-purple identity ([primary]) for selected navigation, text buttons,
  /// input focus, and selected rows on the dark surfaces. Also the fallback for
  /// an unknown/absent id (see [byId]).
  static const BrandPalette classic = BrandPalette(
    id: 'classic',
    primary: AppColors.brand,
    onPrimary: Color(0xFFFFFFFF),
    primaryBright: AppColors.brandBright,
    accent: AppColors.accent,
    accentBright: AppColors.accentBright,
    accentDeep: AppColors.accentDeep,
    onAccent: AppColors.onAccent,
    accentContainer: AppColors.accentContainer,
  );

  /// Black + neon blue: a single electric cyan/blue accent. No purple.
  static const BrandPalette neon = BrandPalette(
    id: 'neon',
    primary: Color(0xFF34C5FF),
    onPrimary: Color(0xFF02161F),
    primaryBright: Color(0xFF7ADBFF),
    accent: Color(0xFF34C5FF),
    accentBright: Color(0xFF7ADBFF),
    accentDeep: Color(0xFF1C9FE6),
    onAccent: Color(0xFF02161F),
    accentContainer: Color(0xFF0D2735),
  );

  /// Black + gold: a rich gold brand *and* gold accent on the dark surfaces, so
  /// the whole theme reads black-and-gold (no violet, no orange/yellow mix).
  static const BrandPalette gold = BrandPalette(
    id: 'gold',
    primary: Color(0xFFF5C518),
    onPrimary: Color(0xFF241C00),
    primaryBright: Color(0xFFFFDD55),
    accent: Color(0xFFF5C518),
    accentBright: Color(0xFFFFDD55),
    accentDeep: Color(0xFFD9A400),
    onAccent: Color(0xFF241C00),
    accentContainer: Color(0xFF332808),
  );

  /// A strictly black-and-white theme for dark mode: pure white accents/brand on
  /// the dark surfaces, with pure-black glyphs. Every colour here is pure black
  /// or pure white — no gray, no tint. (Light mode flips to black-on-white; see
  /// [_blackWhiteLight] / [byId].)
  static const BrandPalette blackWhite = BrandPalette(
    id: 'blackwhite',
    primary: Color(0xFFFFFFFF),
    onPrimary: Color(0xFF000000),
    primaryBright: Color(0xFFFFFFFF),
    accent: Color(0xFFFFFFFF),
    accentBright: Color(0xFFFFFFFF),
    accentDeep: Color(0xFFFFFFFF),
    onAccent: Color(0xFF000000),
    accentContainer: Color(0xFF000000),
  );

  /// The light-mode counterpart of [blackWhite]: pure black accents/brand on
  /// light surfaces. Kept strictly black-and-white too.
  static const BrandPalette blackWhiteLight = BrandPalette(
    id: 'blackwhite',
    primary: Color(0xFF000000),
    onPrimary: Color(0xFFFFFFFF),
    primaryBright: Color(0xFF000000),
    accent: Color(0xFF000000),
    accentBright: Color(0xFF000000),
    accentDeep: Color(0xFF000000),
    onAccent: Color(0xFFFFFFFF),
    accentContainer: Color(0xFFFFFFFF),
  );

  /// The light-mode counterpart of [classic] — the same purple identity and
  /// warm orange energy accent, re-toned for light surfaces.
  ///
  /// The dark tones are not merely dimmer here, they are unreadable: on
  /// [AppColors.lightBackground] the dark [primaryBright] reaches 2.71:1 and the
  /// dark [accent] 2.04:1, both far under the 4.5:1 text bar. Hue is preserved
  /// exactly (251.8° violet, 29.4° orange) so Classic still reads as Linthra —
  /// only lightness moves. See `AppColors` for the per-token contrast figures
  /// and `test/app/light_contrast_test.dart` for the enforced matrix.
  static const BrandPalette classicLight = BrandPalette(
    id: 'classic',
    primary: AppColors.brandLight,
    onPrimary: Color(0xFFFFFFFF),
    primaryBright: AppColors.brandBrightLight,
    accent: AppColors.accentLight,
    accentBright: AppColors.accentBrightLight,
    accentDeep: AppColors.accentDeepLight,
    onAccent: AppColors.onAccentLight,
    accentContainer: AppColors.accentContainerLight,
  );

  /// The light-mode counterpart of [neon]: the same single electric blue accent,
  /// deepened until it carries text on light surfaces (the dark `0xFF34C5FF`
  /// manages 1.9:1 on white).
  static const BrandPalette neonLight = BrandPalette(
    id: 'neon',
    primary: Color(0xFF0A6E96),
    onPrimary: Color(0xFFFFFFFF),
    primaryBright: Color(0xFF085B7C),
    accent: Color(0xFF0A6E96),
    accentBright: Color(0xFF085B7C),
    accentDeep: Color(0xFF064A66),
    onAccent: Color(0xFFFFFFFF),
    accentContainer: Color(0xFFD2EEFA),
  );

  /// The light-mode counterpart of [gold]: the same single gold accent, deepened
  /// into a bronze-gold that survives light surfaces (the dark `0xFFF5C518`
  /// manages 1.7:1 on white — gold is the worst offender of the four).
  static const BrandPalette goldLight = BrandPalette(
    id: 'gold',
    primary: Color(0xFF7A5C00),
    onPrimary: Color(0xFFFFFFFF),
    primaryBright: Color(0xFF6B5000),
    accent: Color(0xFF7A5C00),
    accentBright: Color(0xFF6B5000),
    accentDeep: Color(0xFF574100),
    onAccent: Color(0xFFFFFFFF),
    accentContainer: Color(0xFFFBEFC2),
  );

  /// Every dark palette in [AppIconVariants.all] order; Classic first.
  static const List<BrandPalette> all = <BrandPalette>[
    classic,
    neon,
    gold,
    blackWhite,
  ];

  /// Every light palette, in the same order as [all] — one per entry, so a
  /// variant can never have a dark palette but no light one.
  static const List<BrandPalette> allLight = <BrandPalette>[
    classicLight,
    neonLight,
    goldLight,
    blackWhiteLight,
  ];

  /// Resolves a stored/selected variant [id] to its palette for [brightness],
  /// falling back to Classic for a null, empty, or unrecognised value — the same
  /// "unknown → Classic" rule [AppIconVariants.byId] uses, so the theme can
  /// never land on a palette that does not exist. The fallback is itself
  /// brightness-correct: an unknown id in light mode yields [classicLight], not
  /// the dark Classic.
  ///
  /// Every variant now differs by brightness. Accents chosen for dark surfaces
  /// do *not* stay legible on light ones — that assumption held only while
  /// Linthra was dark-only, and each light palette exists to replace it.
  static BrandPalette byId(String? id, {required Brightness brightness}) {
    final List<BrandPalette> palettes =
        brightness == Brightness.light ? allLight : all;
    final BrandPalette fallback =
        brightness == Brightness.light ? classicLight : classic;
    if (id == null || id.isEmpty) {
      return fallback;
    }
    for (final BrandPalette palette in palettes) {
      if (palette.id == id) {
        return palette;
      }
    }
    return fallback;
  }
}
