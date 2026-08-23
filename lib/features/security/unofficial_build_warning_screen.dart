import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/dimens.dart';
import '../../app/external_link_launcher_provider.dart';
import '../../core/services/build_integrity_service.dart';

/// Full-screen warning shown once per app process before an unverified Android
/// build enters the normal Linthra UI.
///
/// This is deliberately much harder to miss than an About-row badge. It does
/// not claim that an unknown build is malicious; it says only what Linthra can
/// prove: the installed APK is not signed by the official release identity (or
/// that its signing identity could not be verified).
class UnofficialBuildWarningScreen extends ConsumerWidget {
  const UnofficialBuildWarningScreen({
    required this.status,
    required this.onContinue,
    super.key,
  });

  static const String officialDownloadsUrl =
      'https://github.com/TheZupZup/Linthra/releases/latest';

  final BuildIntegrityStatus status;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final bool signatureMismatch =
        status.state == BuildIntegrityState.unofficial;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Card(
                color: colors.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.xl),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(
                        Icons.gpp_bad_outlined,
                        size: 72,
                        color: colors.onErrorContainer,
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      Text(
                        'UNOFFICIAL LINTHRA BUILD',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          color: colors.onErrorContainer,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        signatureMismatch
                            ? 'This Android package is not signed with Linthra\'s official release certificate.'
                            : 'Linthra could not verify this Android package against the official release certificate.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: colors.onErrorContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        'It may have been rebuilt or modified by a third party. '
                        'The Linthra project cannot verify the contents or '
                        'security of this APK. Do not enter server credentials '
                        'unless you trust where this build came from.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.onErrorContainer,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: () => _openOfficialDownloads(context, ref),
                          icon: const Icon(Icons.verified_user_outlined),
                          label: const Text('Get an official build'),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton(
                          onPressed: onContinue,
                          child: const Text('I understand — continue anyway'),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        'This warning returns after the app is restarted.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onErrorContainer,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openOfficialDownloads(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool launched = await ref
        .read(externalLinkLauncherProvider)
        .open(Uri.parse(officialDownloadsUrl));
    if (!launched) {
      messenger.showSnackBar(
        const SnackBar(content: Text("Couldn't open the official downloads.")),
      );
    }
  }
}
