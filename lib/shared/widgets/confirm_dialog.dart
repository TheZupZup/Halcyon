import 'package:flutter/material.dart';

/// Shows a confirmation dialog and resolves to `true` only when the user taps
/// the confirm action (a dismiss/back/Cancel resolves to `false`).
///
/// Every destructive action in Linthra routes through this so the wording is
/// consistent: an explicit `Cancel` and a clearly-labelled action button (e.g.
/// "Remove", "Delete", "Delete from server") — never a vague "OK". When
/// [destructive] is true (the default) the action button is tinted with the
/// error colour so it reads as a deliberate, irreversible-feeling choice.
///
/// Keyboard users get the same care: the actions are laid out (and so traversed)
/// Cancel then action, and the dialog opens with one of them already focused so
/// Enter always has an obvious meaning. For a destructive dialog that is
/// `Cancel` — the safe half of the choice — so a stray Enter or Space can never
/// be the thing that deletes.
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = 'Cancel',
  bool destructive = true,
}) async {
  final bool? result = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) {
      final ThemeData theme = Theme.of(dialogContext);
      return AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: <Widget>[
          TextButton(
            autofocus: destructive,
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(cancelLabel),
          ),
          FilledButton(
            autofocus: !destructive,
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: theme.colorScheme.error,
                    foregroundColor: theme.colorScheme.onError,
                  )
                : null,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );
  return result ?? false;
}
