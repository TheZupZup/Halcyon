import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/audiobookshelf_session.dart';
import '../../core/sources/audiobookshelf/audiobookshelf_api.dart';
import '../../core/sources/audiobookshelf/audiobookshelf_exception.dart';
import '../settings/audiobookshelf/audiobookshelf_settings_controller.dart';
import '../settings/audiobookshelf/audiobookshelf_settings_providers.dart';
import 'audiobooks_library_state.dart';

/// Drives the audiobook browser: picks a library and pages through its books.
///
/// It reads the live session from the connection controller (the one place a
/// signed-in Audiobookshelf session lives) and never touches storage, HTTP
/// headers or the tokens itself. Nothing here goes near the music providers,
/// the music catalog or the source preference: this is the audiobook seam,
/// same as the connection screen.
///
/// Listing only. Opening a book, chapters and playback come with the domain
/// model in the next milestone.
class AudiobooksLibraryController extends Notifier<AudiobooksLibraryState> {
  /// How many books one request asks for. Big enough that most libraries
  /// arrive in a single page, small enough that a large one doesn't spend
  /// seconds parsing before the first row appears.
  static const int pageSize = 100;

  /// The page index the next [loadMore] asks for. Counted rather than
  /// derived from the number of loaded books: a page can come back one book
  /// short because a half-scanned record was skipped, and dividing by
  /// [pageSize] would then ask for the same page again.
  int _nextPage = 1;

  @override
  AudiobooksLibraryState build() => const AudiobooksLibraryState();

  /// Loads the libraries and the first page of the selected one.
  ///
  /// Called when the screen opens. Already-loaded state is kept unless
  /// [force] is set (pull to refresh / the refresh action), so returning to
  /// the screen doesn't re-fetch the whole library.
  Future<void> load({bool force = false}) async {
    final AudiobookshelfSettingsController connection =
        ref.read(audiobookshelfSettingsControllerProvider.notifier);
    // A cold open is still reading the keyring: without this the check below
    // would see "not connected" and offer the connection to a signed-in user.
    await connection.ensureLoaded();
    final AudiobookshelfSession? session = connection.session;
    if (session == null) {
      state = const AudiobooksLibraryState();
      return;
    }
    if (state.hasLoaded && !force && state.errorMessage == null) return;

    state = state.copyWith(isConnected: true, isLoading: true);
    final List<AudiobookshelfLibraryDto> libraries;
    try {
      libraries =
          await ref.read(audiobookshelfClientProvider).fetchLibraries(session);
    } on AudiobookshelfException catch (error) {
      _fail(session, connection, error);
      return;
    }
    if (_isStale(session, connection)) return;

    final List<AudiobookLibrarySummary> bookLibraries =
        <AudiobookLibrarySummary>[
      for (final AudiobookshelfLibraryDto library in libraries)
        // A library that reports no media type at all is treated as books
        // rather than hidden: the browser would otherwise show nothing on a
        // server whose response is a shape older than the one documented.
        if (library.mediaType == null || library.mediaType == 'book')
          AudiobookLibrarySummary(id: library.id, name: library.name),
    ];
    if (bookLibraries.isEmpty) {
      state = const AudiobooksLibraryState(
        isConnected: true,
        hasLoaded: true,
      );
      return;
    }

    state = state.copyWith(
      libraries: bookLibraries,
      selectedLibraryId: _pickLibrary(bookLibraries, session),
      books: const <AudiobookSummary>[],
      totalBooks: 0,
    );
    await _loadFirstPage(session, connection);
  }

  /// Switches to another library and loads its first page. A no-op for the
  /// library already showing.
  Future<void> selectLibrary(String libraryId) async {
    if (libraryId == state.selectedLibraryId) return;
    final AudiobookshelfSettingsController connection =
        ref.read(audiobookshelfSettingsControllerProvider.notifier);
    final AudiobookshelfSession? session = connection.session;
    if (session == null) {
      state = const AudiobooksLibraryState();
      return;
    }
    state = state.copyWith(
      selectedLibraryId: libraryId,
      books: const <AudiobookSummary>[],
      totalBooks: 0,
      isLoading: true,
    );
    await _loadFirstPage(session, connection);
  }

  /// Appends the next page. A no-op when everything is already loaded or a
  /// request is already running, so a keen scroller can't fire two.
  Future<void> loadMore() async {
    if (!state.hasMore || state.isLoading || state.isLoadingMore) return;
    final String? libraryId = state.selectedLibraryId;
    if (libraryId == null) return;
    final AudiobookshelfSettingsController connection =
        ref.read(audiobookshelfSettingsControllerProvider.notifier);
    final AudiobookshelfSession? session = connection.session;
    if (session == null) {
      state = const AudiobooksLibraryState();
      return;
    }

    final int nextPage = _nextPage;
    state = state.copyWith(isLoadingMore: true);
    try {
      final AudiobookshelfLibraryItemsPage page =
          await ref.read(audiobookshelfClientProvider).fetchLibraryItems(
                session,
                libraryId: libraryId,
                limit: pageSize,
                page: nextPage,
              );
      if (_isStale(session, connection)) return;
      // The library it was fetched for may have been switched away from
      // while this was in flight; those books belong to the other list.
      if (libraryId != state.selectedLibraryId) return;
      _nextPage = nextPage + 1;
      final List<AudiobookSummary> books = <AudiobookSummary>[
        ...state.books,
        ..._toSummaries(page.items),
      ];
      state = state.copyWith(
        books: books,
        // An empty page means the server has nothing more to give, whatever
        // its total says (skipped malformed records make the two disagree).
        // Settling the total on what arrived ends the paging instead of
        // leaving a "Load more" that fetches nothing forever.
        totalBooks: page.items.isEmpty ? books.length : page.total,
        isLoadingMore: false,
      );
    } on AudiobookshelfException catch (error) {
      if (_isStale(session, connection)) return;
      // The books already on screen stay there; only the footer reports that
      // the next page didn't come.
      state = state.copyWith(
        isLoadingMore: false,
        errorMessage: error.message,
        errorKind: error.kind,
      );
    }
  }

  /// Re-fetches the libraries and the current library's first page.
  Future<void> refresh() => load(force: true);

  Future<void> _loadFirstPage(
    AudiobookshelfSession session,
    AudiobookshelfSettingsController connection,
  ) async {
    final String? libraryId = state.selectedLibraryId;
    if (libraryId == null) {
      state = state.copyWith(isLoading: false, hasLoaded: true);
      return;
    }
    try {
      final AudiobookshelfLibraryItemsPage page =
          await ref.read(audiobookshelfClientProvider).fetchLibraryItems(
                session,
                libraryId: libraryId,
                limit: pageSize,
                page: 0,
              );
      if (_isStale(session, connection)) return;
      if (libraryId != state.selectedLibraryId) return;
      _nextPage = 1;
      state = state.copyWith(
        books: _toSummaries(page.items),
        totalBooks: page.total,
        isLoading: false,
        hasLoaded: true,
      );
    } on AudiobookshelfException catch (error) {
      _fail(session, connection, error);
    }
  }

  /// The library to open: the one already chosen if it still exists, then the
  /// account's default, then the first. A user who picked a library keeps it
  /// across a refresh.
  String _pickLibrary(
    List<AudiobookLibrarySummary> libraries,
    AudiobookshelfSession session,
  ) {
    final String? current = state.selectedLibraryId;
    for (final AudiobookLibrarySummary library in libraries) {
      if (library.id == current) return library.id;
    }
    for (final AudiobookLibrarySummary library in libraries) {
      if (library.id == session.defaultLibraryId) return library.id;
    }
    return libraries.first.id;
  }

  void _fail(
    AudiobookshelfSession session,
    AudiobookshelfSettingsController connection,
    AudiobookshelfException error,
  ) {
    if (_isStale(session, connection)) return;
    state = state.copyWith(
      isLoading: false,
      isLoadingMore: false,
      hasLoaded: true,
      errorMessage: error.message,
      errorKind: error.kind,
    );
  }

  /// Whether a sign-out (or a sign-in as somebody else) landed while a
  /// request was in flight. The response belongs to the old account, so it is
  /// dropped rather than painted over whatever owns the screen now.
  bool _isStale(
    AudiobookshelfSession session,
    AudiobookshelfSettingsController connection,
  ) =>
      !identical(connection.session, session);

  List<AudiobookSummary> _toSummaries(
    List<AudiobookshelfLibraryItemDto> items,
  ) {
    return <AudiobookSummary>[
      for (final AudiobookshelfLibraryItemDto item in items)
        AudiobookSummary(
          id: item.id,
          title: item.title,
          subtitle: item.subtitle,
          author: item.authorName,
          narrator: item.narratorName,
          series: item.seriesName,
          duration: item.duration,
        ),
    ];
  }
}

final audiobooksLibraryControllerProvider =
    NotifierProvider<AudiobooksLibraryController, AudiobooksLibraryState>(
  AudiobooksLibraryController.new,
);
