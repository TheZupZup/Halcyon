/// Persists which Library tab the user was last on, so the screen reopens where
/// they left it instead of always on Songs.
///
/// The stored value is a single non-secret tab name (`songs`, `albums`,
/// `artists`), never an index: an index silently points at the wrong tab the
/// day one is added or reordered. An absent or unrecognised value reads as
/// `null`, which the screen treats as "the first tab", so a storage hiccup or a
/// renamed tab can never leave the user on a tab that no longer exists.
///
/// Carries no credential, URL, or library content, so a lightweight key/value
/// store is the right weight.
abstract interface class LibraryTabStore {
  /// The persisted tab name, or `null` when there is no usable stored choice.
  Future<String?> read();

  /// Persists [tabName], or clears the choice when `null`.
  Future<void> write(String? tabName);
}
