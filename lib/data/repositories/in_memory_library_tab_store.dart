import '../../core/repositories/library_tab_store.dart';

/// An in-memory [LibraryTabStore] for development and tests. Nothing is
/// persisted; the choice lives only for the lifetime of the instance.
class InMemoryLibraryTabStore implements LibraryTabStore {
  InMemoryLibraryTabStore([this._tabName]);

  String? _tabName;

  @override
  Future<String?> read() async => _tabName;

  @override
  Future<void> write(String? tabName) async {
    _tabName = tabName;
  }
}
