import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/brand_theme.dart';
import 'package:linthra/app/colors.dart';
import 'package:linthra/app/theme.dart';

/// Contrast guardrails for the light themes.
///
/// Linthra still runs dark-only (`themeMode: ThemeMode.dark`), so nothing here
/// is user-visible yet — that is exactly why it needs a test. The light themes
/// were built alongside the dark ones and then never rendered, so their tones
/// silently drifted out of the accessible range: before this suite, Classic's
/// `primaryBright` carried text buttons at 2.71:1 and its `accent` carried
/// SnackBar action text at 1.65:1.
///
/// Every expectation below is read off a real [ThemeData] rather than off the
/// palette constants, so it fails both when a colour regresses *and* when a
/// widget theme is rewired to the wrong slot.
///
/// WCAG 2.1 bars used:
///  - 1.4.3 Contrast (Minimum): 4.5:1 for normal-size text/icons.
///  - 1.4.11 Non-text Contrast: 3:1 for the boundary of an interactive control.
void main() {
  /// WCAG 2.1 relative-luminance contrast ratio, from 1.0 to 21.0.
  ///
  /// [Color.computeLuminance] is already WCAG relative luminance, so this is
  /// just the ratio formula on top of it.
  double contrast(Color a, Color b) {
    final double la = a.computeLuminance();
    final double lb = b.computeLuminance();
    final double lighter = la > lb ? la : lb;
    final double darker = la > lb ? lb : la;
    return (lighter + 0.05) / (darker + 0.05);
  }

  void expectContrast(
    Color foreground,
    Color background, {
    required double atLeast,
    required String reason,
  }) {
    final double ratio = contrast(foreground, background);
    expect(
      ratio,
      greaterThanOrEqualTo(atLeast),
      reason: '$reason — got ${ratio.toStringAsFixed(2)}:1, '
          'need ${atLeast.toStringAsFixed(1)}:1 '
          '($foreground on $background)',
    );
  }

  /// The four light surfaces a foreground can land on, by the theme slot that
  /// carries it. Text buttons in particular appear on all of them.
  List<({String name, Color color})> lightSurfacesOf(ThemeData theme) {
    return <({String name, Color color})>[
      (name: 'scaffold background', color: theme.scaffoldBackgroundColor),
      (name: 'card / dialog / bottom sheet', color: theme.cardTheme.color!),
      (name: 'popup menu', color: theme.popupMenuTheme.color!),
      (name: 'navigation bar', color: theme.navigationBarTheme.backgroundColor!),
    ];
  }

  Color? selectedNavIconColor(ThemeData theme) => theme
      .navigationBarTheme.iconTheme
      ?.resolve(<WidgetState>{WidgetState.selected})?.color;

  Color? selectedNavLabelColor(ThemeData theme) => theme
      .navigationBarTheme.labelTextStyle
      ?.resolve(<WidgetState>{WidgetState.selected})?.color;

  Color? textButtonColor(ThemeData theme) =>
      theme.textButtonTheme.style?.foregroundColor?.resolve(<WidgetState>{});

  /// Every variant, so a light palette can never ship untested.
  final List<({String id, BrandPalette palette})> lightPalettes =
      <({String id, BrandPalette palette})>[
    (id: 'classic', palette: BrandPalettes.classicLight),
    (id: 'neon', palette: BrandPalettes.neonLight),
    (id: 'gold', palette: BrandPalettes.goldLight),
    (id: 'blackwhite', palette: BrandPalettes.blackWhiteLight),
  ];

  group('light theme contrast', () {
    for (final ({String id, BrandPalette palette}) variant in lightPalettes) {
      group(variant.id, () {
        final ThemeData theme = AppTheme.light(variant.palette);

        test('body and secondary text clear 4.5:1 on every light surface', () {
          for (final ({String name, Color color}) surface
              in lightSurfacesOf(theme)) {
            expectContrast(
              theme.colorScheme.onSurface,
              surface.color,
              atLeast: 4.5,
              reason: 'body text on ${surface.name}',
            );
            expectContrast(
              theme.colorScheme.onSurfaceVariant,
              surface.color,
              atLeast: 4.5,
              reason: 'secondary text on ${surface.name}',
            );
          }
        });

        test('text buttons clear 4.5:1 on every light surface', () {
          // The regression that motivated this suite: the dark primaryBright
          // reached only 2.37:1 on the popup-menu surface.
          final Color? foreground = textButtonColor(theme);
          expect(foreground, isNotNull);
          for (final ({String name, Color color}) surface
              in lightSurfacesOf(theme)) {
            expectContrast(
              foreground!,
              surface.color,
              atLeast: 4.5,
              reason: 'text button label on ${surface.name}',
            );
          }
        });

        test('selected navigation icon and label clear 4.5:1', () {
          final Color background = theme.navigationBarTheme.backgroundColor!;
          expectContrast(
            selectedNavIconColor(theme)!,
            background,
            atLeast: 4.5,
            reason: 'selected navigation icon',
          );
          expectContrast(
            selectedNavLabelColor(theme)!,
            background,
            atLeast: 4.5,
            reason: 'selected navigation label',
          );
        });

        test('unselected navigation icon and label clear 4.5:1', () {
          final Color background = theme.navigationBarTheme.backgroundColor!;
          final Color? icon = theme.navigationBarTheme.iconTheme
              ?.resolve(<WidgetState>{})?.color;
          final Color? label = theme.navigationBarTheme.labelTextStyle
              ?.resolve(<WidgetState>{})?.color;
          expectContrast(
            icon!,
            background,
            atLeast: 4.5,
            reason: 'unselected navigation icon',
          );
          expectContrast(
            label!,
            background,
            atLeast: 4.5,
            reason: 'unselected navigation label',
          );
        });

        test('SnackBar action text clears 4.5:1 on the SnackBar', () {
          // accent doubles as action-text colour, which is the tightest
          // constraint on the light accent tone.
          expectContrast(
            theme.snackBarTheme.actionTextColor!,
            theme.snackBarTheme.backgroundColor!,
            atLeast: 4.5,
            reason: 'SnackBar action text',
          );
          expectContrast(
            theme.snackBarTheme.contentTextStyle!.color!,
            theme.snackBarTheme.backgroundColor!,
            atLeast: 4.5,
            reason: 'SnackBar content text',
          );
        });

        test('filled call-to-action label clears 4.5:1 on its fill', () {
          final ButtonStyle? style = theme.filledButtonTheme.style;
          expectContrast(
            style!.foregroundColor!.resolve(<WidgetState>{})!,
            style.backgroundColor!.resolve(<WidgetState>{})!,
            atLeast: 4.5,
            reason: 'filled button label on its accent fill',
          );
        });

        test('selected chip label clears 4.5:1 on the selected chip', () {
          expectContrast(
            theme.chipTheme.secondaryLabelStyle!.color!,
            theme.chipTheme.selectedColor!,
            atLeast: 4.5,
            reason: 'selected chip label',
          );
          expectContrast(
            theme.chipTheme.labelStyle!.color!,
            theme.chipTheme.backgroundColor!,
            atLeast: 4.5,
            reason: 'unselected chip label',
          );
        });

        test('error colour clears 4.5:1 on every light surface', () {
          for (final ({String name, Color color}) surface
              in lightSurfacesOf(theme)) {
            expectContrast(
              theme.colorScheme.error,
              surface.color,
              atLeast: 4.5,
              reason: 'error text on ${surface.name}',
            );
          }
        });

        test('control borders clear the 3:1 non-text bar', () {
          // WCAG 1.4.11: these delimit interactive controls.
          final OutlineInputBorder enabled =
              theme.inputDecorationTheme.enabledBorder! as OutlineInputBorder;
          final OutlineInputBorder focused =
              theme.inputDecorationTheme.focusedBorder! as OutlineInputBorder;
          final Color fill = theme.inputDecorationTheme.fillColor!;
          expectContrast(
            enabled.borderSide.color,
            fill,
            atLeast: 3.0,
            reason: 'search / text field border',
          );
          expectContrast(
            focused.borderSide.color,
            fill,
            atLeast: 3.0,
            reason: 'focused text field border',
          );
          expectContrast(
            theme.colorScheme.outline,
            theme.scaffoldBackgroundColor,
            atLeast: 3.0,
            reason: 'outlined button / chip border',
          );
        });

        test('the play button gradient stays visible on light surfaces', () {
          final LinthraAccents accents = theme.extension<LinthraAccents>()!;
          for (final ({String name, Color color}) surface
              in lightSurfacesOf(theme)) {
            expectContrast(
              accents.accentBright,
              surface.color,
              atLeast: 3.0,
              reason: 'play button gradient top on ${surface.name}',
            );
            expectContrast(
              accents.accentDeep,
              surface.color,
              atLeast: 3.0,
              reason: 'play button gradient bottom on ${surface.name}',
            );
          }
        });

        test('no palette tone is a dark slab on a light surface', () {
          // accentContainer used to be a dark brown (0xFF3A2A16). Its own
          // foreground contrast passed, so only a lightness check catches it:
          // a container on a light theme must itself be light.
          expect(
            theme.colorScheme.secondaryContainer.computeLuminance(),
            greaterThan(0.5),
            reason: '${variant.id}: secondaryContainer must be a light tint, '
                'not a dark block punched into the light UI',
          );
        });
      });
    }
  });

  group('light palette registry', () {
    test('every variant resolves to a distinct light palette', () {
      for (final ({String id, BrandPalette palette}) variant in lightPalettes) {
        final BrandPalette resolved =
            BrandPalettes.byId(variant.id, brightness: Brightness.light);
        expect(resolved, same(variant.palette));
        expect(resolved.id, variant.id);
      }
    });

    test('light and dark palettes are genuinely different tones', () {
      // Guards against a future variant being added to allLight by copying its
      // dark entry — which is precisely the bug this PR fixes.
      for (final ({String id, BrandPalette palette}) variant in lightPalettes) {
        if (variant.id == 'blackwhite') {
          continue; // Pure black/white by design; asserted in brand_theme_test.
        }
        final BrandPalette dark =
            BrandPalettes.byId(variant.id, brightness: Brightness.dark);
        expect(
          variant.palette.accent,
          isNot(dark.accent),
          reason: '${variant.id}: light accent must be re-toned, not reused',
        );
        expect(
          variant.palette.primaryBright,
          isNot(dark.primaryBright),
          reason: '${variant.id}: light primaryBright must be re-toned',
        );
      }
    });

    test('allLight covers exactly the same variants as all', () {
      expect(
        BrandPalettes.allLight.map((BrandPalette p) => p.id).toList(),
        BrandPalettes.all.map((BrandPalette p) => p.id).toList(),
      );
    });

    test('an unknown id falls back to Classic in the right brightness', () {
      expect(
        BrandPalettes.byId('does-not-exist', brightness: Brightness.light),
        same(BrandPalettes.classicLight),
      );
      expect(
        BrandPalettes.byId('does-not-exist', brightness: Brightness.dark),
        same(BrandPalettes.classic),
      );
    });

    test('Classic keeps its Linthra hues in light mode', () {
      // "Accessible" must not mean "beige". Classic stays a violet identity
      // paired with a warm orange energy accent — the same two hue families as
      // dark mode, only re-toned for light surfaces.
      final HSLColor violet = HSLColor.fromColor(BrandPalettes.classicLight.primary);
      final HSLColor darkViolet = HSLColor.fromColor(BrandPalettes.classic.primary);
      final HSLColor orange = HSLColor.fromColor(BrandPalettes.classicLight.accent);
      final HSLColor darkOrange = HSLColor.fromColor(BrandPalettes.classic.accent);

      expect(
        (violet.hue - darkViolet.hue).abs(),
        lessThan(2.0),
        reason: 'light Classic primary must keep the Linthra violet hue',
      );
      expect(
        (orange.hue - darkOrange.hue).abs(),
        lessThan(2.0),
        reason: 'light Classic accent must keep the Linthra orange hue',
      );
      // Still two different hues, as in dark mode.
      expect((violet.hue - orange.hue).abs(), greaterThan(90));
    });
  });

  group('dark theme is untouched by the light hardening', () {
    // This PR must not change a single rendered dark pixel.
    final ThemeData dark = AppTheme.dark(BrandPalettes.classic);

    test('dark still uses one outline tone for borders and dividers', () {
      expect(dark.colorScheme.outline, AppColors.darkOutline);
      expect(dark.colorScheme.outlineVariant, AppColors.darkOutline);
      expect(dark.dividerTheme.color, AppColors.darkOutline);
    });

    test('dark keeps the shared error red', () {
      expect(dark.colorScheme.error, AppColors.error);
    });

    test('dark Classic keeps its original brand tones', () {
      expect(dark.colorScheme.primary, AppColors.brand);
      expect(dark.colorScheme.secondary, AppColors.accent);
      expect(dark.colorScheme.onSecondary, AppColors.onAccent);
      expect(dark.colorScheme.secondaryContainer, AppColors.accentContainer);
    });
  });
}
