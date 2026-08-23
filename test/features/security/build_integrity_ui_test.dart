import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/external_link_launcher_provider.dart';
import 'package:linthra/core/services/build_integrity_service.dart';
import 'package:linthra/core/services/external_link_launcher.dart';
import 'package:linthra/data/repositories/build_integrity_provider.dart';
import 'package:linthra/features/security/build_integrity_card.dart';
import 'package:linthra/features/security/unofficial_build_warning_screen.dart';

class _FakeLinkLauncher implements ExternalLinkLauncher {
  Uri? opened;

  @override
  Future<bool> open(Uri url) async {
    opened = url;
    return true;
  }
}

class _FakeBuildIntegrityService implements BuildIntegrityService {
  const _FakeBuildIntegrityService(this.status);

  final BuildIntegrityStatus status;

  @override
  Future<BuildIntegrityStatus> check() async => status;
}

void main() {
  const BuildIntegrityStatus unofficial = BuildIntegrityStatus(
    state: BuildIntegrityState.unofficial,
    certificateSha256: 'deadbeef',
  );

  testWidgets('unofficial build warning is prominent and explicit',
      (tester) async {
    final _FakeLinkLauncher launcher = _FakeLinkLauncher();
    bool continued = false;

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          externalLinkLauncherProvider.overrideWithValue(launcher),
        ],
        child: MaterialApp(
          home: UnofficialBuildWarningScreen(
            status: unofficial,
            onContinue: () => continued = true,
          ),
        ),
      ),
    );

    expect(find.text('UNOFFICIAL LINTHRA BUILD'), findsOneWidget);
    expect(
      find.textContaining('not signed with Linthra\'s official release'),
      findsOneWidget,
    );
    expect(find.textContaining('server credentials'), findsOneWidget);
    expect(find.text('Get an official build'), findsOneWidget);
    expect(find.text('I understand — continue anyway'), findsOneWidget);

    await tester.tap(find.text('Get an official build'));
    await tester.pump();
    expect(
      launcher.opened,
      Uri.parse(UnofficialBuildWarningScreen.officialDownloadsUrl),
    );

    await tester.tap(find.text('I understand — continue anyway'));
    expect(continued, isTrue);
  });

  testWidgets('About card keeps an unofficial build visibly marked',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          buildIntegrityServiceProvider.overrideWithValue(
            const _FakeBuildIntegrityService(unofficial),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: BuildIntegrityCard()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Build integrity'), findsOneWidget);
    expect(find.text('UNOFFICIAL BUILD'), findsOneWidget);
    expect(find.textContaining('verified release signing identity'),
        findsOneWidget);
  });

  testWidgets('About card marks an official build without a warning',
      (tester) async {
    const BuildIntegrityStatus official = BuildIntegrityStatus(
      state: BuildIntegrityState.official,
      certificateSha256: 'trusted',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          buildIntegrityServiceProvider.overrideWithValue(
            const _FakeBuildIntegrityService(official),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: BuildIntegrityCard()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Official signed build'), findsOneWidget);
    expect(find.text('UNOFFICIAL BUILD'), findsNothing);
  });
}
