import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/lifecycle/async_disposal_registry.dart';
import 'linthra_database.dart';

/// Test seam for the app-wide database's storage.
///
/// Production leaves this null so [LinthraDatabase] opens its own on-disk
/// SQLite connection. Tests inject `NativeDatabase.memory()` to exercise the
/// real provider — including its teardown — without touching the filesystem.
/// Same shape as `linuxAudioPlayerProvider`'s seam.
final linthraDatabaseExecutorProvider = Provider<QueryExecutor?>((ref) => null);

/// The app-wide [LinthraDatabase]. The underlying SQLite connection is opened
/// lazily on first query and closed when the provider is disposed, so nothing
/// touches the disk until the catalog is actually read or written.
///
/// The close is registered with [AsyncDisposalRef.onDisposeAsync], not plain
/// `ref.onDispose`: `db.close()` is asynchronous, and a restart that reopens
/// the same database file while the previous connection is still closing is
/// exactly the race `ApplicationHandle.shutdown()` promises not to leave behind.
final linthraDatabaseProvider = Provider<LinthraDatabase>((ref) {
  final QueryExecutor? executor = ref.watch(linthraDatabaseExecutorProvider);
  final LinthraDatabase db = executor == null
      ? LinthraDatabase()
      : LinthraDatabase.forTesting(executor);
  ref.onDisposeAsync(db.close);
  return db;
});
