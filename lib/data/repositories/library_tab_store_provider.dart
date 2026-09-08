import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/repositories/library_tab_store.dart';
import 'in_memory_library_tab_store.dart';
import 'shared_preferences_library_tab_store.dart';

/// The single [LibraryTabStore] the Library screen remembers its tab through.
///
/// Defaults to the in-memory implementation so widget and unit tests stay free
/// of platform plugins. The running app overrides this with
/// [sharedPreferencesLibraryTabStoreOverride] so the choice survives a restart,
/// which is when landing on the wrong tab is most annoying.
final libraryTabStoreProvider = Provider<LibraryTabStore>((ref) {
  return InMemoryLibraryTabStore();
});

/// Production binding: persists the last Library tab via `shared_preferences`.
/// Applied in `main`.
final sharedPreferencesLibraryTabStoreOverride =
    libraryTabStoreProvider.overrideWithValue(
  const SharedPreferencesLibraryTabStore(),
);
