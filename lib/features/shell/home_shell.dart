import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../player/mini_player.dart';

/// The persistent app frame: hosts the active tab and the app's primary
/// navigation. Tab state is owned by go_router's [StatefulNavigationShell], so
/// each tab keeps its own stack and scroll position across switches.
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

  /// Wide Linux windows get a persistent desktop navigation region instead of
  /// the phone-oriented bottom navigation bar. Keeping the breakpoint here
  /// gives the shell one reusable presentation seam instead of scattering
  /// platform checks through feature screens.
  static const double desktopNavigationBreakpoint = 900;

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
    navigationShell.goBranch(
      index,
      initialLocation: index == navigationShell.currentIndex,
    );
  }

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

  bool _usesDesktopNavigation(
    BuildContext context,
    BoxConstraints constraints,
  ) {
    return Theme.of(context).platform == TargetPlatform.linux &&
        constraints.maxWidth >= desktopNavigationBreakpoint;
  }

  Widget _buildNavigationRail() {
    return FocusTraversalOrder(
      order: const NumericFocusOrder(2),
      child: FocusTraversalGroup(
        child: SafeArea(
          right: false,
          child: NavigationRail(
            selectedIndex: navigationShell.currentIndex,
            onDestinationSelected: _onDestinationSelected,
            labelType: NavigationRailLabelType.all,
            groupAlignment: -1,
            destinations: [
              for (final NavigationDestination destination in _destinations)
                NavigationRailDestination(
                  icon: destination.icon,
                  selectedIcon: destination.selectedIcon,
                  label: Text(destination.label),
                ),
            ],
          ),
        ),
      ),
    );
  }

  NavigationBar _buildNavigationBar() {
    return NavigationBar(
      selectedIndex: navigationShell.currentIndex,
      onDestinationSelected: _onDestinationSelected,
      destinations: _destinations,
    );
  }

  @override
  Widget build(BuildContext context) {
    return BackButtonListener(
      onBackButtonPressed: _handleSystemBack,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool desktop = _usesDesktopNavigation(context, constraints);

          // Keep StatefulNavigationShell at the same element position across
          // the 900 px breakpoint. Only the two chrome slots before it change
          // between real desktop widgets and zero-sized placeholders, so an
          // inactive branch's Navigator stack and scroll state survive resize.
          return Scaffold(
            body: FocusTraversalGroup(
              policy: OrderedTraversalPolicy(),
              child: Row(
                children: <Widget>[
                  if (desktop)
                    _buildNavigationRail()
                  else
                    const SizedBox.shrink(),
                  if (desktop)
                    const VerticalDivider(width: 1)
                  else
                    const SizedBox.shrink(),
                  Expanded(
                    child: FocusTraversalOrder(
                      order: const NumericFocusOrder(1),
                      child: FocusTraversalGroup(
                        child: Column(
                          children: <Widget>[
                            Expanded(child: navigationShell),
                            const MiniPlayer(),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            bottomNavigationBar: desktop ? null : _buildNavigationBar(),
          );
        },
      ),
    );
  }
}
