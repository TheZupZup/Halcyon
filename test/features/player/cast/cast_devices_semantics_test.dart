import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/cast_state.dart';
import 'package:linthra/features/player/cast/cast_devices_sheet.dart';
import 'package:linthra/features/player/cast/cast_providers.dart';

import 'fake_cast_service.dart';

/// Choosing where the music plays is a connection-management surface: which
/// device is in use, and whether the receiver is muted, are both carried by a
/// glyph. The connected row is also deliberately not tappable, which without a
/// state to explain it just reads as a row that stopped working.
const CastDevice _living = CastDevice(id: 'd1', name: 'Living Room');
const CastDevice _kitchen = CastDevice(id: 'd2', name: 'Kitchen');

Future<void> _pumpSheet(WidgetTester tester, CastState state) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        castServiceProvider.overrideWithValue(FakeCastService(initial: state)),
      ],
      child: const MaterialApp(home: Scaffold(body: CastDevicesSheet())),
    ),
  );
  // Not pumpAndSettle: the connecting/searching states spin forever.
  await tester.pump();
}

/// The slider's own semantics node. [Slider] is a semantic boundary that sits
/// below its widget, so it is found by role rather than by widget type.
SemanticsNode _sliderNode() => find.semantics
    .byPredicate(
      (SemanticsNode node) => node.flagsCollection.isSlider,
      describeMatch: (_) => 'the cast volume slider',
    )
    .evaluate()
    .single;

void main() {
  group('CastDevicesSheet semantics', () {
    testWidgets('the connected device is exposed as selected, and named',
        (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pumpSheet(
        tester,
        const CastState(
          availability: CastAvailability.connected,
          devices: <CastDevice>[_living, _kitchen],
          connectedDevice: _living,
        ),
      );

      final SemanticsNode connected =
          tester.getSemantics(find.text('Living Room'));
      expect(connected.flagsCollection.isSelected, Tristate.isTrue);
      // The glyph is the only other thing that marks the row; it says so.
      expect(connected.label, contains('Connected'));

      final SemanticsNode other = tester.getSemantics(find.text('Kitchen'));
      expect(other.flagsCollection.isSelected, Tristate.isFalse);
      expect(other.label, isNot(contains('Connected')));
      handle.dispose();
    });

    testWidgets('with nothing connected, no row claims to be', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pumpSheet(
        tester,
        const CastState(
          availability: CastAvailability.idle,
          devices: <CastDevice>[_living, _kitchen],
        ),
      );

      expect(
        tester
            .getSemantics(find.text('Living Room'))
            .flagsCollection
            .isSelected,
        Tristate.isFalse,
      );
      expect(
        tester.getSemantics(find.text('Living Room')).label,
        isNot(contains('Connected')),
      );
      handle.dispose();
    });

    testWidgets('the volume slider is named and reports a usable value',
        (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pumpSheet(
        tester,
        const CastState(
          availability: CastAvailability.connected,
          devices: <CastDevice>[_living],
          connectedDevice: _living,
          volume: 0.4,
          supportsVolumeControl: true,
        ),
      );

      final SemanticsNode slider = _sliderNode();
      expect(slider.label, 'Cast volume');
      // A percentage, not a raw 0–1 fraction.
      expect(slider.value, '40%');
      handle.dispose();
    });

    testWidgets('mute reads as a toggle rather than two swapping buttons',
        (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pumpSheet(
        tester,
        const CastState(
          availability: CastAvailability.connected,
          devices: <CastDevice>[_living],
          connectedDevice: _living,
          volume: 0.4,
          supportsVolumeControl: true,
          muted: true,
        ),
      );

      final SemanticsNode mute = tester.getSemantics(find.byTooltip('Unmute'));
      expect(mute.flagsCollection.isSelected, Tristate.isTrue);
      handle.dispose();
    });

    testWidgets('an unmuted receiver says it is not muted', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pumpSheet(
        tester,
        const CastState(
          availability: CastAvailability.connected,
          devices: <CastDevice>[_living],
          connectedDevice: _living,
          volume: 0.4,
          supportsVolumeControl: true,
        ),
      );

      final SemanticsNode mute = tester.getSemantics(find.byTooltip('Mute'));
      // Still a toggle, just an off one — not a button with no state.
      expect(mute.flagsCollection.isSelected, Tristate.isFalse);
      handle.dispose();
    });

    testWidgets('a device that cannot be volume-controlled says so, disabled',
        (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pumpSheet(
        tester,
        const CastState(
          availability: CastAvailability.connected,
          devices: <CastDevice>[_living],
          connectedDevice: _living,
        ),
      );

      final SemanticsNode slider = _sliderNode();
      expect(slider.flagsCollection.isEnabled, Tristate.isFalse);
      // Named even while disabled, so the reason the note gives has something
      // to attach to.
      expect(slider.label, 'Cast volume');
      handle.dispose();
    });
  });
}
