import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/shell/home_shell.dart';

import '../player/fake_playback_controller.dart';

/// Keyboard focus has to move through the frame the way it reads: everything in
/// the active tab first — pane by pane, in visual order — and only then the
/// persistent bar under it, with Shift+Tab retracing exactly that path.
///
/// That is what the shell's layout already gives (the tab fills the body, the
/// mini-player and destinations sit below it, and nothing overlaps), so this
/// pins it down against a future layout change that would quietly interleave
/// the two — the failure a keyboard user notices immediately and a mouse user
/// never sees. The two-pane tab below stands in for the wide desktop window,
/// where the order matters most.
///
/// The wide Linux window has to read the same way, and does not get there on
/// its own: with the rail beside the page rather than under it, the default
/// reading-order policy sorts both by geometry and splits the rail around the
/// content, leaving the first destination before the page and the rest after
/// it. HomeShell orders the two groups explicitly instead, so crossing the
/// breakpoint moves the destinations without reordering them.

/// A stand-in tab laid out as two side-by-side panes, the shape a desktop
/// window puts content in.
class _TwoPaneTab extends StatelessWidget {
  const _TwoPaneTab();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              children: <Widget>[
                TextButton(onPressed: () {}, child: const Text('left top')),
                TextButton(onPressed: () {}, child: const Text('left bottom')),
              ],
            ),
          ),
          Expanded(
            child: Column(
              children: <Widget>[
                // Offset so the two panes occupy distinct bands and the
                // expected order is unambiguous.
                const SizedBox(height: 200),
                TextButton(onPressed: () {}, child: const Text('right top')),
                TextButton(onPressed: () {}, child: const Text('right bottom')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

GoRouter _router(GlobalKey<NavigatorState> rootKey,
    List<GlobalKey<NavigatorState>> branchKeys) {
  return GoRouter(
    navigatorKey: rootKey,
    initialLocation: '/one',
    routes: <RouteBase>[
      StatefulShellRoute.indexedStack(
        builder: (_, __, StatefulNavigationShell shell) => HomeShell(
          navigationShell: shell,
          rootNavigatorKey: rootKey,
          branchNavigatorKeys: branchKeys,
        ),
        branches: <StatefulShellBranch>[
          for (final (int i, String path) in <String>[
            '/one',
            '/two',
            '/three',
            '/four',
            '/five',
          ].indexed)
            StatefulShellBranch(
              navigatorKey: branchKeys[i],
              routes: <RouteBase>[
                GoRoute(
                  path: path,
                  builder: (_, __) =>
                      i == 0 ? const _TwoPaneTab() : const Scaffold(),
                ),
              ],
            ),
        ],
      ),
    ],
  );
}

/// The label of whatever currently holds focus, or the navigation destination
/// it sits in — enough to describe the traversal order in one list.
String? _focusedLabel(WidgetTester tester) {
  final BuildContext? context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return null;
  final Finder text = find.descendant(
    of: find.byWidget(context.widget),
    matching: find.byType(Text),
  );
  if (text.evaluate().isEmpty) return null;
  return tester.widget<Text>(text.first).data;
}

void main() {
  testWidgets('Tab walks the whole tab before reaching the navigation bar',
      (tester) async {
    final GlobalKey<NavigatorState> rootKey = GlobalKey<NavigatorState>();
    final List<GlobalKey<NavigatorState>> branchKeys =
        <GlobalKey<NavigatorState>>[
      for (int i = 0; i < 5; i++) GlobalKey<NavigatorState>(),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          // Nothing is playing, so the mini-player collapses and the bottom
          // group is the destinations alone.
          playbackControllerProvider
              .overrideWithValue(FakePlaybackController()),
        ],
        child: MaterialApp.router(routerConfig: _router(rootKey, branchKeys)),
      ),
    );
    await tester.pumpAndSettle();

    Focus.of(tester.element(find.text('left top'))).requestFocus();
    await tester.pump();

    final List<String?> order = <String?>[_focusedLabel(tester)];
    for (int i = 0; i < 8; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      order.add(_focusedLabel(tester));
    }

    // The tab's four controls first, in visual order, and only then the
    // destinations under it — never a pane interleaved with the bar.
    expect(
      order.take(4),
      <String>['left top', 'left bottom', 'right top', 'right bottom'],
    );
    expect(order.skip(4), <String>[
      'Library',
      'Folders',
      'Playlists',
      'Downloads',
      'Settings',
    ]);
  });

  testWidgets('Shift+Tab comes back the same way', (tester) async {
    final GlobalKey<NavigatorState> rootKey = GlobalKey<NavigatorState>();
    final List<GlobalKey<NavigatorState>> branchKeys =
        <GlobalKey<NavigatorState>>[
      for (int i = 0; i < 5; i++) GlobalKey<NavigatorState>(),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          // Nothing is playing, so the mini-player collapses and the bottom
          // group is the destinations alone.
          playbackControllerProvider
              .overrideWithValue(FakePlaybackController()),
        ],
        child: MaterialApp.router(routerConfig: _router(rootKey, branchKeys)),
      ),
    );
    await tester.pumpAndSettle();

    Focus.of(tester.element(find.text('Library'))).requestFocus();
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
    await tester.pump();

    expect(_focusedLabel(tester), 'right bottom');
  });

  testWidgets('the selected destination is exposed as selected',
      (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    final GlobalKey<NavigatorState> rootKey = GlobalKey<NavigatorState>();
    final List<GlobalKey<NavigatorState>> branchKeys =
        <GlobalKey<NavigatorState>>[
      for (int i = 0; i < 5; i++) GlobalKey<NavigatorState>(),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          // Nothing is playing, so the mini-player collapses and the bottom
          // group is the destinations alone.
          playbackControllerProvider
              .overrideWithValue(FakePlaybackController()),
        ],
        child: MaterialApp.router(routerConfig: _router(rootKey, branchKeys)),
      ),
    );
    await tester.pumpAndSettle();

    // Library is the active branch; the others must not claim to be.
    expect(
      tester.getSemantics(find.text('Library')).flagsCollection.isSelected,
      Tristate.isTrue,
    );
    expect(
      tester.getSemantics(find.text('Playlists')).flagsCollection.isSelected,
      Tristate.isFalse,
    );
    handle.dispose();
  });

  testWidgets('the desktop rail is walked whole, after the tab',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final GlobalKey<NavigatorState> rootKey = GlobalKey<NavigatorState>();
    final List<GlobalKey<NavigatorState>> branchKeys =
        <GlobalKey<NavigatorState>>[
      for (int i = 0; i < 5; i++) GlobalKey<NavigatorState>(),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          playbackControllerProvider
              .overrideWithValue(FakePlaybackController()),
        ],
        child: MaterialApp.router(
          theme: ThemeData(platform: TargetPlatform.linux),
          routerConfig: _router(rootKey, branchKeys),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The layout under test: the rail beside the page, not the bar under it.
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);

    Focus.of(tester.element(find.text('left top'))).requestFocus();
    await tester.pump();

    final List<String?> order = <String?>[_focusedLabel(tester)];
    for (int i = 0; i < 8; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      order.add(_focusedLabel(tester));
    }

    // Exactly the bottom-bar order: the tab's four controls in visual order,
    // then the four destinations in rail order. Without the explicit grouping
    // the rail splits and Library lands last, after Settings.
    expect(
      order.take(4),
      <String>['left top', 'left bottom', 'right top', 'right bottom'],
    );
    expect(order.skip(4), <String>[
      'Library',
      'Folders',
      'Playlists',
      'Downloads',
      'Settings',
    ]);
  });
}
