import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_info.dart';
import '../core/services/active_playback_controller.dart';
import '../core/services/notification_permission.dart';
import '../core/services/stability_diagnostics.dart';
import '../features/appearance/app_icon_controller.dart';
import '../features/appearance/custom_brand_palette.dart';
import '../features/appearance/custom_theme_controller.dart';
import '../features/appearance/theme_mode_controller.dart';
import '../features/library/remote_library_refresher.dart';
import '../features/onboarding/onboarding_controller.dart';
import '../features/player/player_providers.dart';
import '../features/support/support_actions_provider.dart';
import '../features/support/supporter_entitlement.dart';
import 'brand_theme.dart';
import 'router.dart';
import 'theme.dart';

/// The notification-permission seam the app asks through after onboarding.
///
/// Defaults to the `permission_handler`-backed request (a no-op off Android and
/// when already granted); tests override it with a fake so pumping the app
/// never triggers a real OS prompt.
final notificationPermissionProvider = Provider<NotificationPermission>((ref) {
  return const PermissionHandlerNotificationPermission();
});

/// Root widget. Linthra follows the phone's light/dark setting by default; the
/// user can pin Light or Dark in Settings → Appearance, and that choice is read
/// from storage before the first frame (see `readStoredThemeMode`) so launching
/// never flashes the wrong theme.
class LinthraApp extends ConsumerStatefulWidget {
  const LinthraApp({super.key});

  @override
  ConsumerState<LinthraApp> createState() => _LinthraAppState();
}

class _LinthraAppState extends ConsumerState<LinthraApp>
    with WidgetsBindingObserver {
  bool _notificationPermissionRequested = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  void _requestNotificationPermissionOnce() {
    if (_notificationPermissionRequested) return;
    _notificationPermissionRequested = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // First installs reach this only after the user leaves onboarding, so the
      // very first thing Linthra does is never an unexplained Android permission
      // prompt. Existing/update installs keep the previous behaviour and ask on
      // their first app frame when needed.
      ref
          .read(notificationPermissionProvider)
          .ensureGranted()
          .catchError((Object _) {});
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // A secret-free breadcrumb (debug only): freezes/ANRs cluster around
    // background/foreground, so logging the transition makes them correlatable.
    StabilityDiagnostics.lifecycle(state.name);
    // On a background transition (screen off / app hidden), snapshot the
    // playback status so a "music stopped when I locked the phone" report can
    // show what state playback was in at that exact boundary. This only reads
    // the controller's status — it never pauses, stops, or disposes playback.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.inactive) {
      final status = ref.read(playbackControllerProvider).state.status;
      StabilityDiagnostics.backgroundPlaybackState(status.name);
    }
    // Returning from the background while casting: re-sync from the receiver so
    // the position the UI shows is fresh. This never starts local playback —
    // backgrounding/foregrounding the app must not recreate or resume the local
    // engine while a cast session owns playback.
    if (state == AppLifecycleState.resumed) {
      final controller = ref.read(playbackControllerProvider);
      if (controller is ActivePlaybackController) {
        controller.onAppResumed();
      }
      // Smart refresh: pick up playlist/favourite changes made on a connected
      // server (Navidrome/Jellyfin) from another client while we were away, and
      // retry any heart that hadn't reached the server yet. Throttled,
      // best-effort, and offline-tolerant — never blocks the resume.
      ref.read(remoteLibraryRefresherProvider).refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(appRouterProvider);
    final themeMode = ref.watch(themeModeControllerProvider);
    final variant = ref.watch(appIconControllerProvider);
    final customTheme = ref.watch(customThemeControllerProvider);
    final distribution = ref.watch(supportDistributionProvider);
    final supporterEntitlement = ref.watch(supporterEntitlementProvider);
    final bool onboardingCompleted = ref.watch(onboardingControllerProvider);

    if (onboardingCompleted) {
      _requestNotificationPermissionOnce();
    }

    BrandPalette paletteFor(Brightness brightness) {
      final bool mayApplyCustomPalette = distribution.offersCustomPalette &&
          supporterEntitlement.allowsCosmetics &&
          customTheme.enabled;
      if (mayApplyCustomPalette) {
        return customBrandPalette(customTheme, brightness: brightness);
      }
      return BrandPalettes.byId(variant.id, brightness: brightness);
    }

    return MaterialApp.router(
      title: AppInfo.name,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(paletteFor(Brightness.light)),
      darkTheme: AppTheme.dark(paletteFor(Brightness.dark)),
      // Watching the controller means a change repaints every screen at once.
      // ThemeMode.system additionally makes MaterialApp rebuild when the phone
      // flips light/dark while Linthra is open — no listener of our own needed.
      themeMode: themeMode.materialThemeMode,
      routerConfig: router,
    );
  }
}
