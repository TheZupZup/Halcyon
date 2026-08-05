import 'package:flutter/widgets.dart';

import '../../core/models/track.dart';

/// The multi-select bookkeeping every track-list screen needs, in one place.
///
/// Library, Album detail and Artist detail each grew their own copy of the same
/// four operations (start, toggle, clear, resolve-to-tracks). This mixin is that
/// logic extracted once so a new screen — Favorites — can adopt multi-select
/// without adding a fifth copy. The existing three are deliberately left alone
/// here: retrofitting them is a behaviour-neutral refactor that belongs in its
/// own change, not in a Favorites usability PR.
///
/// Selection is keyed by the provider-namespaced [Track.uri], never the bare id,
/// so a Jellyfin and a Navidrome copy that share a server-side id can't be
/// selected (or bulk-acted on) as if they were one row.
///
/// The host owns the visuals: it decides what the selection app bar offers and
/// what a tap does. This only tracks *what is selected*, and calls [setState] so
/// the host rebuilds.
mixin TrackSelectionMixin<T extends StatefulWidget> on State<T> {
  final Set<String> _selectedUris = <String>{};

  /// Whether the screen is currently in selection mode. Driven purely by the
  /// selection being non-empty, so clearing the last row always leaves the mode
  /// — there is no separate flag that can drift out of step with the set.
  bool get selectionActive => _selectedUris.isNotEmpty;

  /// The selected uris, for handing to a list widget. Read-only to callers.
  Set<String> get selectedUris => Set<String>.unmodifiable(_selectedUris);

  /// The selected rows resolved against [tracks], in list order.
  ///
  /// Resolving through the live list (rather than holding [Track] objects) is
  /// what keeps a selection honest when the catalog changes underneath it: a row
  /// removed by a sync or a delete simply stops resolving, so the count and the
  /// available actions never describe a track that is no longer there.
  List<Track> selectedFrom(List<Track> tracks) => <Track>[
        for (final Track track in tracks)
          if (_selectedUris.contains(track.uri)) track,
      ];

  /// Enters selection mode with [track] as the first row (a long-press).
  void startSelection(Track track) {
    setState(() {
      _selectedUris
        ..clear()
        ..add(track.uri);
    });
  }

  /// Adds or removes [track]. Removing the last row leaves selection mode.
  void toggleSelection(Track track) {
    setState(() {
      if (!_selectedUris.add(track.uri)) {
        _selectedUris.remove(track.uri);
      }
    });
  }

  /// Leaves selection mode, dropping every selected row.
  void exitSelection() {
    if (_selectedUris.isEmpty) return;
    setState(_selectedUris.clear);
  }
}
