import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/selected_music_folder_repository_provider.dart';
import 'library_controller.dart';
import 'library_providers.dart';

/// Owns the user's chosen local-music location: a folder path/SAF URI, or an
/// app-defined source sentinel such as Android's device-wide MediaStore library.
class SelectedFolderController extends AsyncNotifier<String?> {
  @override
  Future<String?> build() {
    return ref.read(selectedMusicFolderRepositoryProvider).getSelectedFolder();
  }

  /// Opens the folder picker and, if the user chooses one, persists it.
  Future<String?> pickAndPersist() async {
    final picked = await ref.read(folderPickerServiceProvider).pickFolder();
    if (picked == null || picked.isEmpty) {
      return null;
    }
    await setAndPersist(picked);
    return picked;
  }

  /// Persists a known local-library location without opening the folder picker.
  /// Used by Android's explicit device-wide MediaStore mode.
  Future<void> setAndPersist(String location) async {
    if (location.isEmpty) return;
    // A source change supersedes pending scans before persistence can yield.
    final library = ref.read(libraryControllerProvider.notifier);
    library.invalidatePendingScans();
    await library.waitForLocalMutations();
    await ref
        .read(selectedMusicFolderRepositoryProvider)
        .setSelectedFolder(location);
    state = AsyncData<String?>(location);
  }

  /// Forgets the current selection.
  Future<void> clear() async {
    final library = ref.read(libraryControllerProvider.notifier);
    library.invalidatePendingScans();
    await library.waitForLocalMutations();
    await ref.read(selectedMusicFolderRepositoryProvider).clearSelectedFolder();
    state = const AsyncData<String?>(null);
  }
}

final selectedFolderControllerProvider =
    AsyncNotifierProvider<SelectedFolderController, String?>(
  SelectedFolderController.new,
);
