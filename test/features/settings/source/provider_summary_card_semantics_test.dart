import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/features/settings/source/provider_summary_cards.dart';

/// A music-source card is a single choice — "manage this source" — described by
/// the block of text inside it. It should therefore arrive as one announcement
/// carrying the source, its connection state and its detail line, with its
/// actions as separate buttons after it. And because these are the surfaces
/// that hold server addresses and credentials, the card must never say more
/// than what is already on screen.
Future<void> _pumpCard(
  WidgetTester tester, {
  required String statusLabel,
  String? detail,
  List<Widget> actions = const <Widget>[],
  VoidCallback? onManage,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ProviderSummaryCard(
          icon: Icons.cloud_outlined,
          title: 'Jellyfin',
          statusLabel: statusLabel,
          statusTone: ProviderStatusTone.positive,
          detail: detail,
          actions: actions,
          onManage: onManage ?? () {},
        ),
      ),
    ),
  );
  await tester.pump();
}

/// The card's own node — the one a screen reader lands on for the card body.
SemanticsNode _card(WidgetTester tester) =>
    tester.getSemantics(find.text('Jellyfin'));

void main() {
  group('ProviderSummaryCard semantics', () {
    testWidgets('reads as one button: source, state, detail', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pumpCard(
        tester,
        statusLabel: 'Connected',
        detail: 'Signed in as amelia',
      );

      final SemanticsNode node = _card(tester);
      expect(node.flagsCollection.isButton, isTrue);
      expect(node.label, contains('Jellyfin'));
      expect(node.label, contains('Connected'));
      expect(node.label, contains('Signed in as amelia'));
      // One node, not four fragments in a row.
      expect(node.label, 'Jellyfin\nConnected\nSigned in as amelia');
      handle.dispose();
    });

    testWidgets('a disconnected source says so', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pumpCard(
        tester,
        statusLabel: 'Not connected',
        detail: 'Sign in to stream your Jellyfin library.',
      );

      expect(_card(tester).label, contains('Not connected'));
      handle.dispose();
    });

    testWidgets('the card says nothing that is not on screen', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      // A detail line is the only place a card ever shows an address, and it
      // is shown, not synthesised: the announcement must match it exactly and
      // must not reach for anything else the provider knows.
      await _pumpCard(
        tester,
        statusLabel: 'Connected',
        detail: 'Home server',
      );

      expect(_card(tester).label, 'Jellyfin\nConnected\nHome server');
      handle.dispose();
    });

    testWidgets('the decorative glyph and status dot add no nodes',
        (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pumpCard(tester, statusLabel: 'Connected');

      // Nothing unnamed to step through before reaching the card's own text.
      expect(find.semantics.byFlag(SemanticsFlag.isImage), findsNothing);
      expect(_card(tester).label, 'Jellyfin\nConnected');
      handle.dispose();
    });

    testWidgets('actions stay separate, named buttons outside the card node',
        (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pumpCard(
        tester,
        statusLabel: 'Connected',
        detail: 'Signed in as amelia',
        actions: <Widget>[
          FilledButton(onPressed: () {}, child: const Text('Sync now')),
          OutlinedButton(onPressed: () {}, child: const Text('Manage')),
        ],
      );

      // Merging the card body must not have swallowed the buttons.
      expect(_card(tester).label, isNot(contains('Sync now')));
      expect(
        tester.getSemantics(find.text('Sync now')).flagsCollection.isButton,
        isTrue,
      );
      expect(
        tester.getSemantics(find.text('Manage')).flagsCollection.isButton,
        isTrue,
      );
      handle.dispose();
    });

    testWidgets('the whole card is the manage action', (tester) async {
      int manages = 0;
      await _pumpCard(
        tester,
        statusLabel: 'Connected',
        onManage: () => manages++,
      );

      await tester.tap(find.text('Jellyfin'));
      await tester.pump();
      expect(manages, 1);
    });
  });
}
