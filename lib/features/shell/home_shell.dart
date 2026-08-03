import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../player/mini_player.dart';

/// The persistent app frame: hosts the active tab and the bottom navigation
/// bar. Tab state is owned by go_router's [StatefulNavigationShell], so each
/// tab keeps its own stack and scroll position across switches.
class HomeShell extends StatelessWidget {
  const HomeShell({
    required this.navigationShell,
    required this.rootNavigatorKey,
    required this.branchNavigatorKeys,
    super.key,
  }) : assert(branchNavigatorKeys.length == 4);

  final StatefulNavigationShell navigationShell;
  final GlobalKey<NavigatorState> rootNavigatorKey;
  final List<GlobalKey<NavigatorState>> branchNavigatorKeys;

  static const _destinations = <NavigationDestination>[
    NavigationDestination(
      icon: Icon(Icons.library_music_outlined),
      selectedIcon: Icon(Icons.library_music),
      label: 'Library',
    ),
    NavigationDestination(
      icon: Icon(Icons.queue_music_outlined),
      selectedIcon: Icon(Icons.queue_music),
      label: 'Playlists',
    ),
    NavigationDestination(
      icon: Icon(Icons.download_outlined),
      selectedIcon: Icon(Icons.download),
      label: 'Downloads',
    ),
    NavigationDestination(
      icon: Icon(Icons.settings_outlined),
      selectedIcon: Icon(Icons.settings),
      label: 'Settings',
    ),
  ];

  void _onDestinationSelected(int index) {
    // `initialLocation: true` re-pops a tab to its root when re-tapped.
    navigationShell.goBranch(
      index,
      initialLocation: index == navigationShell.currentIndex,
    );
  }

  /// Gives every real navigation layer a chance before Android is allowed to
  /// close the app:
  ///
  /// 1. a root-level route such as the full player or a dialog;
  /// 2. the active tab's detail stack;
  /// 3. an internal BackButtonListener such as folder browsing or selection;
  /// 4. finally, a secondary bottom-navigation tab returns to Library.
  ///
  /// Only the root of Library returns `false` all the way to Android, which is
  /// the one place where closing Linthra is the expected Back action.
  Future<bool> _handleSystemBack() async {
    if (rootNavigatorKey.currentState?.canPop() ?? false) return false;

    final int currentIndex = navigationShell.currentIndex;
    final NavigatorState? activeBranch =
        branchNavigatorKeys[currentIndex].currentState;
    if (activeBranch?.canPop() ?? false) return false;

    if (currentIndex == 0) return false;
    navigationShell.goBranch(0);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return BackButtonListener(
      onBackButtonPressed: _handleSystemBack,
      child: Scaffold(
        body: navigationShell,
        // The mini-player rides just above the navigation bar so it stays
        // visible on every tab (and collapses to nothing when no track is
        // loaded). The full PlayerScreen is pushed above this shell, so the two
        // never overlap.
        bottomNavigationBar: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const MiniPlayer(),
            NavigationBar(
              selectedIndex: navigationShell.currentIndex,
              onDestinationSelected: _onDestinationSelected,
              destinations: _destinations,
            ),
          ],
        ),
      ),
    );
  }
}
