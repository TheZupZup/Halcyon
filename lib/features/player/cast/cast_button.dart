import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/cast_state.dart';
import 'cast_devices_sheet.dart';
import 'cast_providers.dart';

/// The now-playing cast affordance. Renders from [castStateProvider] and opens
/// the [CastDevicesSheet]; it never talks to a cast SDK directly.
///
/// Honest by design: with the shipped [UnavailableCastService] the button is
/// visible but muted, so it never implies casting works today. When connected it
/// switches to the filled cast-connected glyph. Tapping always opens the sheet,
/// which states the real status — including that casting is temporarily
/// withheld while the security containment is in place.
class CastButton extends ConsumerWidget {
  const CastButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final service = ref.watch(castServiceProvider);
    final state = ref.watch(castStateProvider).valueOrNull ?? service.state;

    final Color color;
    if (state.isConnected) {
      color = theme.colorScheme.primary;
    } else if (state.isAvailable) {
      color = theme.colorScheme.onSurface.withValues(alpha: 0.85);
    } else {
      // Unavailable: present but visibly inactive, so it never implies casting
      // works today.
      color = theme.colorScheme.onSurface.withValues(alpha: 0.38);
    }

    return IconButton(
      onPressed: () => _openSheet(context),
      icon: Icon(state.isConnected ? Icons.cast_connected : Icons.cast),
      color: color,
      isSelected: state.isConnected,
      tooltip: _tooltip(state),
    );
  }

  /// A carried message on an unavailable state means casting is off for its own
  /// reason (the security containment), not merely unsupported here — the sheet
  /// spells it out, and the tooltip shouldn't promise it is coming.
  String _tooltip(CastState state) {
    if (state.isAvailable) return 'Cast';
    return state.message != null
        ? 'Cast (temporarily unavailable)'
        : 'Cast (coming soon)';
  }

  void _openSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => const CastDevicesSheet(),
    );
  }
}
