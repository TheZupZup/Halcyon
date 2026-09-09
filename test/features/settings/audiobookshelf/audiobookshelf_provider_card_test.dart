import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/audiobookshelf_session.dart';
import 'package:linthra/core/sources/audiobookshelf/audiobookshelf_api.dart';
import 'package:linthra/data/repositories/audiobookshelf_session_store_provider.dart';
import 'package:linthra/data/repositories/in_memory_audiobookshelf_session_store.dart';
import 'package:linthra/features/settings/audiobookshelf/audiobookshelf_provider_card.dart';
import 'package:linthra/features/settings/audiobookshelf/audiobookshelf_settings_providers.dart';

import '../../../core/sources/audiobookshelf/fake_audiobookshelf_client.dart';

const _session = AudiobookshelfSession(
  baseUrl: 'https://audiobooks.example.com',
  userId: 'user-1',
  accessToken: 'tok-1',
  userName: 'alice',
  serverVersion: '2.17.0',
);

Future<void> _pump(
  WidgetTester tester, {
  AudiobookshelfSession? savedSession,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        audiobookshelfClientProvider.overrideWithValue(
          FakeAudiobookshelfClient(
            serverStatus: const AudiobookshelfServerStatus(
              serverVersion: '2.17.0',
              isInitialized: true,
            ),
          ),
        ),
        audiobookshelfSessionStoreProvider.overrideWithValue(
          InMemoryAudiobookshelfSessionStore(initialSession: savedSession),
        ),
      ],
      child: const MaterialApp(
        home: Scaffold(body: AudiobookshelfProviderCard()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('offers Connect when no server is set up', (tester) async {
    await _pump(tester);

    expect(find.text('Audiobookshelf'), findsOneWidget);
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
    expect(find.text('Manage'), findsNothing);
  });

  testWidgets('shows the signed-in account once connected', (tester) async {
    await _pump(tester, savedSession: _session);

    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Signed in as alice'), findsOneWidget);
    expect(find.text('Manage'), findsOneWidget);
    // The way into the books themselves, offered only once there is a server
    // to browse.
    expect(find.text('Browse'), findsOneWidget);
  });

  testWidgets('offers no Browse without a connection', (tester) async {
    await _pump(tester);

    expect(find.text('Browse'), findsNothing);
  });

  testWidgets('Connect opens the connection form', (tester) async {
    await _pump(tester);

    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(find.text('Server URL'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets('never renders the access token', (tester) async {
    await _pump(tester, savedSession: _session);

    for (final Text text in tester.widgetList<Text>(find.byType(Text))) {
      expect(text.data ?? '', isNot(contains('tok-1')));
    }
  });
}
