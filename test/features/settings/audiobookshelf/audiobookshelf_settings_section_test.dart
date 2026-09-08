import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/audiobookshelf_session.dart';
import 'package:linthra/core/sources/audiobookshelf/audiobookshelf_api.dart';
import 'package:linthra/data/repositories/audiobookshelf_session_store_provider.dart';
import 'package:linthra/data/repositories/in_memory_audiobookshelf_session_store.dart';
import 'package:linthra/features/settings/audiobookshelf/audiobookshelf_settings_providers.dart';
import 'package:linthra/features/settings/audiobookshelf/audiobookshelf_settings_section.dart';

import '../../../core/sources/audiobookshelf/fake_audiobookshelf_client.dart';

const _session = AudiobookshelfSession(
  baseUrl: 'https://audiobooks.example.com',
  userId: 'user-1',
  accessToken: 'tok-1',
  userName: 'alice',
  serverVersion: '2.17.0',
);

const _status = AudiobookshelfServerStatus(
  serverVersion: '2.17.0',
  isInitialized: true,
);

const _authResult = AudiobookshelfAuthResult(
  userId: 'user-1',
  accessToken: 'tok-1',
  userName: 'alice',
);

Future<void> _pump(
  WidgetTester tester, {
  FakeAudiobookshelfClient? client,
  AudiobookshelfSession? savedSession,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        audiobookshelfClientProvider.overrideWithValue(
          client ??
              FakeAudiobookshelfClient(
                serverStatus: _status,
                authResult: _authResult,
              ),
        ),
        audiobookshelfSessionStoreProvider.overrideWithValue(
          InMemoryAudiobookshelfSessionStore(initialSession: savedSession),
        ),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: AudiobookshelfSettingsSection()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders the connection form', (tester) async {
    await _pump(tester);

    expect(find.text('Audiobookshelf'), findsOneWidget);
    expect(find.text('Server URL'), findsOneWidget);
    expect(find.text('Username'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    expect(find.text('Test connection'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets('Test connection needs only the address, Sign in needs all three',
      (tester) async {
    await _pump(tester);

    OutlinedButton test() => tester.widget<OutlinedButton>(
          find.widgetWithText(OutlinedButton, 'Test connection'),
        );
    FilledButton signIn() => tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Sign in'),
        );

    expect(test().onPressed, isNull);
    expect(signIn().onPressed, isNull);

    await tester.enterText(
      find.byType(TextField).at(0),
      'audiobooks.example.com',
    );
    await tester.pump();

    // The address alone is testable: /status takes no credentials.
    expect(test().onPressed, isNotNull);
    expect(signIn().onPressed, isNull);

    await tester.enterText(find.byType(TextField).at(1), 'alice');
    await tester.enterText(find.byType(TextField).at(2), 'hunter2');
    await tester.pump();

    expect(signIn().onPressed, isNotNull);
  });

  testWidgets('signing in shows the account and its libraries', (tester) async {
    await _pump(
      tester,
      client: FakeAudiobookshelfClient(
        serverStatus: _status,
        authResult: _authResult,
        libraries: const <AudiobookshelfLibraryDto>[
          AudiobookshelfLibraryDto(
            id: 'lib-1',
            name: 'Audiobooks',
            mediaType: 'book',
          ),
        ],
      ),
    );

    await tester.enterText(
      find.byType(TextField).at(0),
      'audiobooks.example.com',
    );
    await tester.enterText(find.byType(TextField).at(1), 'alice');
    await tester.enterText(find.byType(TextField).at(2), 'hunter2');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    expect(find.text('Signed in as alice'), findsOneWidget);
    expect(find.text('1 library'), findsOneWidget);
    expect(find.text('Audiobooks'), findsOneWidget);
    expect(find.text('Sign out & clear'), findsOneWidget);
    // The form is gone once connected, so no password field lingers.
    expect(find.text('Password'), findsNothing);
  });

  testWidgets('a restored session lists libraries when the sheet opens',
      (tester) async {
    final client = FakeAudiobookshelfClient(
      serverStatus: _status,
      authResult: _authResult,
      libraries: const <AudiobookshelfLibraryDto>[
        AudiobookshelfLibraryDto(id: 'lib-1', name: 'Audiobooks'),
        AudiobookshelfLibraryDto(id: 'lib-2', name: 'Podcasts'),
      ],
    );
    await _pump(tester, client: client, savedSession: _session);

    expect(find.text('2 libraries'), findsOneWidget);
    expect(find.text('Podcasts'), findsOneWidget);
  });

  testWidgets('a failed test connection shows a friendly error',
      (tester) async {
    await _pump(
      tester,
      client: FakeAudiobookshelfClient(),
    );

    await tester.enterText(find.byType(TextField).at(0), 'example.com');
    await tester.pump();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Test connection'));
    await tester.pumpAndSettle();

    expect(find.textContaining("Couldn't reach the server"), findsOneWidget);
    // Still on the form, nothing pretends to be connected.
    expect(find.text('Sign in'), findsOneWidget);
  });
}
