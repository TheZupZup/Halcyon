import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/external_link_launcher_provider.dart';
import 'package:linthra/core/services/external_link_launcher.dart';
import 'package:linthra/core/sources/plex/plex_api.dart';
import 'package:linthra/core/sources/plex/plex_pin_auth.dart';
import 'package:linthra/data/repositories/in_memory_plex_session_store.dart';
import 'package:linthra/data/repositories/plex_session_store_provider.dart';
import 'package:linthra/features/settings/plex/plex_settings_providers.dart';
import 'package:linthra/features/settings/plex/plex_settings_section.dart';

import '../../../core/sources/plex/fake_plex_client.dart';
import '../../../core/sources/plex/fake_plex_tv_client.dart';

/// Server-connection screens are the one place in Linthra that holds a secret,
/// and semantics is an easy place to leak one: a label built from the server
/// address and the token is invisible on screen and spoken out loud. This walks
/// the whole semantics tree of the Plex section — the surface with the most
/// sensitive field, a bare access token — and asserts the token never appears
/// in anything a screen reader would read.
const String _token = 'super-secret-plex-token';

const PlexDirectory _musicSection =
    PlexDirectory(key: '5', title: 'Music', type: 'artist');

class _NoopLauncher implements ExternalLinkLauncher {
  @override
  Future<bool> open(Uri url) async => true;
}

Future<void> _pump(WidgetTester tester) async {
  final FakePlexClient client =
      FakePlexClient(sections: const <PlexDirectory>[_musicSection]);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        plexClientProvider.overrideWithValue(client),
        plexSessionStoreProvider.overrideWithValue(InMemoryPlexSessionStore()),
        plexPinAuthProvider.overrideWith(
          (ref) => PlexPinAuth(
            tvClient: FakePlexTvClient(),
            serverClient: client,
            identity: ref.watch(plexClientIdentityProvider),
            wait: (_) async {},
          ),
        ),
        externalLinkLauncherProvider.overrideWithValue(_NoopLauncher()),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: PlexSettingsSection()),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// Everything the semantics tree would say out loud, flattened.
List<String> _spokenStrings(WidgetTester tester) {
  final List<String> spoken = <String>[];
  void visit(SemanticsNode node) {
    spoken
      ..add(node.label)
      ..add(node.value)
      ..add(node.hint)
      ..add(node.tooltip)
      ..add(node.increasedValue)
      ..add(node.decreasedValue);
    node.visitChildren((SemanticsNode child) {
      visit(child);
      return true;
    });
  }

  for (final SemanticsNode root in tester.binding.rootElement!
      .findRenderObject()!
      .debugSemantics!
      .debugListChildrenInOrder(DebugSemanticsDumpOrder.traversalOrder)) {
    visit(root);
  }
  return spoken.where((String s) => s.isNotEmpty).toList();
}

void main() {
  group('Plex settings semantics never expose the token', () {
    testWidgets('an entered token is obscured in semantics too',
        (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pump(tester);

      await tester.tap(find.text('Manual setup (advanced)'));
      await tester.pump();
      await tester.enterText(
        find.byType(TextField).at(0),
        'https://plex.example.com:32400',
      );
      await tester.enterText(find.byType(TextField).at(1), _token);
      await tester.pump();

      final List<String> spoken = _spokenStrings(tester);
      expect(
        spoken.any((String s) => s.contains(_token)),
        isFalse,
        reason: 'the token must never be spoken: $spoken',
      );
      // The field is announced as an obscured text field, not as empty.
      expect(
        find.semantics.byFlag(SemanticsFlag.isObscured),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('revealing the token is a deliberate, named action',
        (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pump(tester);

      await tester.tap(find.text('Manual setup (advanced)'));
      await tester.pump();

      // Icon-only eye toggle: it has to say which way it goes.
      expect(find.byTooltip('Show token'), findsOneWidget);
      expect(find.byTooltip('Hide token'), findsNothing);

      await tester.tap(find.byTooltip('Show token'));
      await tester.pump();
      expect(find.byTooltip('Hide token'), findsOneWidget);
      handle.dispose();
    });
  });
}
