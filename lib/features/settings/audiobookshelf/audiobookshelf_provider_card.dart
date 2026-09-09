import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes.dart';
import '../source/provider_summary_cards.dart';
import 'audiobookshelf_settings_controller.dart';
import 'audiobookshelf_settings_section.dart';
import 'audiobookshelf_settings_state.dart';

/// The Audiobookshelf connection as a compact card on the Connections page,
/// reusing the same [ProviderSummaryCard] shape the music sources use so the
/// page reads as one list.
///
/// It sits under its own "Audiobooks" heading rather than among the music
/// sources: Audiobookshelf is not a music provider, it doesn't sync into the
/// music catalog, and nothing about the existing sources changes because it is
/// here.
class AudiobookshelfProviderCard extends ConsumerWidget {
  const AudiobookshelfProviderCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AudiobookshelfSettingsState state =
        ref.watch(audiobookshelfSettingsControllerProvider);
    final bool connected = state.isConnected;

    void manage() => showProviderSettingsSheet(
          context,
          child: const AudiobookshelfSettingsSection(),
        );

    String? detail;
    bool detailIsError = false;
    if (!connected) {
      detail = 'Sign in to browse your self-hosted audiobooks.';
    } else if (state.errorMessage != null) {
      detail = state.errorMessage;
      detailIsError = true;
    } else if (state.isLoadingLibraries) {
      detail = 'Loading your libraries…';
    } else if (state.libraries.isNotEmpty) {
      detail = state.libraries.length == 1
          ? '1 library • ${state.libraries.first.name}'
          : '${state.libraries.length} libraries';
    } else if (state.username != null && state.username!.isNotEmpty) {
      detail = 'Signed in as ${state.username}';
    } else {
      detail = state.baseUrl;
    }

    return ProviderSummaryCard(
      icon: Icons.headphones_outlined,
      title: 'Audiobookshelf',
      statusLabel: connected ? 'Connected' : 'Not connected',
      statusTone:
          connected ? ProviderStatusTone.positive : ProviderStatusTone.neutral,
      detail: detail,
      detailIsError: detailIsError,
      onManage: manage,
      actions: connected
          ? <Widget>[
              _ManageAction(onPressed: manage),
              // The way into the books themselves. It sits here only until
              // Audiobooks gets its own navigation destination, its own
              // change agreed on the tracking issue.
              FilledButton(
                onPressed: () => context.go(AppRoutes.audiobooks),
                child: const Text('Browse'),
              ),
            ]
          : <Widget>[
              FilledButton(onPressed: manage, child: const Text('Connect')),
            ],
    );
  }
}

/// The card's explicit "Manage" button. The music cards pair Manage with a
/// "Sync now" action; Audiobookshelf has nothing to sync into the music
/// catalog and never will, so it pairs with "Browse" instead.
class _ManageAction extends StatelessWidget {
  const _ManageAction({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(onPressed: onPressed, child: const Text('Manage'));
  }
}
