import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../features/library/widgets/quick_search_overlay.dart';

/// Opens the quick-search overlay.
///
/// A named intent rather than a bare callback so the binding stays declarative:
/// another surface (a toolbar button, a future command palette) can invoke the
/// same intent instead of re-implementing "open quick search".
class OpenQuickSearchIntent extends Intent {
  const OpenQuickSearchIntent();
}

/// Binds the quick-search keyboard shortcuts over [child].
///
/// Ctrl+K and Ctrl+F both open the overlay: Ctrl+K is what recent desktop apps
/// use for a jump-to palette, and Ctrl+F is what people who grew up on "find"
/// press first. Neither is gated on the platform — Linthra decides presentation
/// on the width it is given, not on `Platform.isLinux`, and a shortcut can only
/// fire when a real keyboard sends it, so a phone is unaffected while an Android
/// tablet with a keyboard case gets it for free.
///
/// It is mounted **above the router**, wrapping everything the app ever shows,
/// rather than inside the navigation shell. Key events travel up from whatever
/// has focus, so a binding inside the shell would be invisible to routes pushed
/// over it — including the full-screen Now Playing screen, which is exactly
/// where opening a song from quick search leaves you. Sitting above the router
/// means every route is a descendant and the shortcut works everywhere.
///
/// That position is also why it takes [navigatorKey] instead of using its own
/// context: above the router there is no `Navigator` ancestor to show a dialog
/// on, so the overlay is shown on the root navigator by key.
class QuickSearchShortcuts extends StatefulWidget {
  const QuickSearchShortcuts({
    required this.navigatorKey,
    required this.child,
    super.key,
  });

  /// The root navigator the overlay is shown on (see [rootNavigatorKeyProvider]).
  final GlobalKey<NavigatorState> navigatorKey;

  final Widget child;

  /// The bindings, exposed so a test can assert the app really is reachable by
  /// the documented keys rather than by a private copy of them.
  static const Map<ShortcutActivator, Intent> shortcuts =
      <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.keyK, control: true):
        OpenQuickSearchIntent(),
    SingleActivator(LogicalKeyboardKey.keyF, control: true):
        OpenQuickSearchIntent(),
  };

  @override
  State<QuickSearchShortcuts> createState() => _QuickSearchShortcutsState();
}

class _QuickSearchShortcutsState extends State<QuickSearchShortcuts> {
  /// Guards against a second overlay stacking on the first — holding Ctrl+K, or
  /// pressing it again while the overlay already has focus, must be a no-op.
  bool _showing = false;

  Future<void> _open() async {
    if (_showing) return;
    // Null only before the navigator's first build, when there is nothing to
    // search over yet; a dropped keystroke there is the right outcome.
    final BuildContext? navigatorContext = widget.navigatorKey.currentContext;
    if (navigatorContext == null) return;
    _showing = true;
    try {
      await showQuickSearch(navigatorContext);
    } finally {
      _showing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: QuickSearchShortcuts.shortcuts,
      child: Actions(
        actions: <Type, Action<Intent>>{
          OpenQuickSearchIntent: CallbackAction<OpenQuickSearchIntent>(
            onInvoke: (_) {
              unawaited(_open());
              return null;
            },
          ),
        },
        child: widget.child,
      ),
    );
  }
}
