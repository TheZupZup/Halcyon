import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/dimens.dart';
import '../../core/services/build_integrity_service.dart';
import '../../data/repositories/build_integrity_provider.dart';

/// Permanent Settings -> About provenance indicator.
///
/// Even after the startup warning is acknowledged, an unverified build remains
/// visibly marked for as long as that APK is installed.
class BuildIntegrityCard extends ConsumerWidget {
  const BuildIntegrityCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<BuildIntegrityStatus> value =
        ref.watch(buildIntegrityStatusProvider);
    final BuildIntegrityStatus? status = value.valueOrNull;
    if (status == null) {
      return const SizedBox.shrink();
    }

    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final bool warning = status.shouldWarn;
    final Color foreground =
        warning ? colors.onErrorContainer : colors.onSurface;

    return Card(
      color: warning ? colors.errorContainer : null,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              warning ? Icons.gpp_bad_outlined : Icons.verified_user_outlined,
              color: warning ? colors.onErrorContainer : colors.primary,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Build integrity',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: foreground,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    status.label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: foreground,
                      fontWeight: warning ? FontWeight.w800 : FontWeight.w600,
                    ),
                  ),
                  if (warning) ...<Widget>[
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      'This APK is outside Linthra\'s verified release signing identity.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: foreground,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
