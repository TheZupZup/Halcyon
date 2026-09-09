import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/shell/home_shell.dart';

import '../library/fake_music_library_repository.dart';
import '../player/fake_playback_controller.dart';

/// A branch screen with a text field, so the shortcut is exercised in the state
/// it actually has to survive: a user who is already typing somewhere.
class _BranchScreen extends StatelessWidget {
  const _BranchScreen(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text('$label screen'),
            const SizedBox(
              width: 200,
              child: TextField(key: Key('branch_field')),
            ),
          ],
        ),
      ),
    );
  }
}

GoRouter _router(
  GlobalKey<NavigatorState> rootKey,
  List<GlobalKey<NavigatorState>> branchKeys,
) {
  const List<String> paths = <String>[
    '/library',
    '/folders',
    '/playlists',
    '/downloads',
    '/settings',
  ];
  const List<String> labels = <String>[
    'Library',
    'Folders',
    'Playlists',
    'Downloads',
    'Settings',
  ];

  return GoRouter(
    navigatorKey: rootKey,
    initialLocation: paths.first,
    routes: <RouteBase>[
      StatefulShellRoute.indexedStack(
        builder: (_, __, StatefulNavigationShell shell) => HomeShell(
          navigationShell: shell,
          rootNavigatorKey: rootKey,
          branchNavigatorKeys: branchKeys,
        ),
        branches: <StatefulShellBranch>[
          for (int i = 0; i < paths.length; i++)
            StatefulShellBranch(
              navigatorKey: branchKeys[i],
              routes: <RouteBase>[
                GoRoute(
                  path: paths[i],
                  builder: (_, __) => _BranchScreen(labels[i]),
                ),
              ],
            ),
        ],
      ),
    ],
  );
}

Future<void> _pumpShell(WidgetTester tester) async {
  final GlobalKey<NavigatorState> rootKey = GlobalKey<NavigatorState>();
  final List<GlobalKey<NavigatorState>> branchKeys =
      <GlobalKey<NavigatorState>>[
    for (int i = 0; i < 5; i++) GlobalKey<NavigatorState>(),
  ];

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        musicLibraryRepositoryProvider
            .overrideWithValue(FakeMusicLibraryRepository()),
        playbackControllerProvider.overrideWithValue(FakePlaybackController()),
      ],
      child: MaterialApp.router(routerConfig: _router(rootKey, branchKeys)),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pressChord(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

Finder get _overlayField => find.byKey(const Key('quick_search_field'));

void main() {
  group('Quick search shortcuts', () {
    testWidgets('Ctrl+K opens the overlay from inside the shell',
        (tester) async {
      await _pumpShell(tester);

      expect(_overlayField, findsNothing);

      await _pressChord(tester, LogicalKeyboardKey.keyK);

      expect(_overlayField, findsOneWidget);
      // The tab underneath keeps its place: nothing navigated.
      expect(find.text('Library screen'), findsOneWidget);
    });

    testWidgets('Ctrl+F opens it too', (tester) async {
      await _pumpShell(tester);

      await _pressChord(tester, LogicalKeyboardKey.keyF);

      expect(_overlayField, findsOneWidget);
    });

    testWidgets('the shortcut works from any tab, not just Library',
        (tester) async {
      await _pumpShell(tester);

      await tester.tap(find.text('Playlists'));
      await tester.pumpAndSettle();
      expect(find.text('Playlists screen'), findsOneWidget);

      await _pressChord(tester, LogicalKeyboardKey.keyK);

      expect(_overlayField, findsOneWidget);
      expect(find.text('Playlists screen'), findsOneWidget);
    });

    testWidgets('it opens even while a field on the page has focus',
        (tester) async {
      await _pumpShell(tester);

      await tester.tap(find.byKey(const Key('branch_field')));
      await tester.pumpAndSettle();

      await _pressChord(tester, LogicalKeyboardKey.keyK);

      expect(_overlayField, findsOneWidget);
    });

    testWidgets('pressing it again while open does not stack a second overlay',
        (tester) async {
      await _pumpShell(tester);

      await _pressChord(tester, LogicalKeyboardKey.keyK);
      await _pressChord(tester, LogicalKeyboardKey.keyK);

      expect(_overlayField, findsOneWidget);

      // One Escape is enough to get back to the app.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(_overlayField, findsNothing);
      expect(find.text('Library screen'), findsOneWidget);
    });
  });
}
