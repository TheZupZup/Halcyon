import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/dimens.dart';
import '../../core/models/theme_mode_preference.dart';
import 'theme_mode_controller.dart';

/// The System / Light / Dark picker, shown at the top of Settings → Appearance.
///
/// Sits above the icon/branding picker because it is the coarser choice: which
/// surfaces the app paints on, before which accent paints them.
class ThemeModeCard extends ConsumerWidget {
  const ThemeModeCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final ThemeModePreference selected = ref.watch(themeModeControllerProvider);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  Icons.contrast_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    'Appearance',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              selected == ThemeModePreference.system
                  ? 'Linthra follows your phone’s light/dark setting.'
                  : 'Linthra always uses the ${selected.label.toLowerCase()} '
                      'theme, whatever your phone is set to.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            // SegmentedButton gives the three options one clear selected state
            // and the right semantics for screen readers for free.
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<ThemeModePreference>(
                segments: <ButtonSegment<ThemeModePreference>>[
                  for (final ThemeModePreference preference
                      in ThemeModePreference.values)
                    ButtonSegment<ThemeModePreference>(
                      value: preference,
                      label: Text(preference.label),
                      icon: Icon(preference.icon),
                      tooltip: preference.label,
                    ),
                ],
                selected: <ThemeModePreference>{selected},
                showSelectedIcon: false,
                onSelectionChanged: (Set<ThemeModePreference> selection) {
                  ref
                      .read(themeModeControllerProvider.notifier)
                      .select(selection.first);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
