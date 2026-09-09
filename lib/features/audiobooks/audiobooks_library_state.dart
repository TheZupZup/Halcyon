import '../../core/sources/audiobookshelf/audiobookshelf_exception.dart';

/// One book as the browse list renders it.
///
/// Deliberately not the wire DTO and deliberately not a playback model: the
/// list shows a title, who wrote and read it, which series it belongs to and
/// how long it runs. Chapters, audio files and progress arrive with the
/// domain model in the next milestone, and nothing here invites the rest of
/// the app to depend on Audiobookshelf's response shape in the meantime.
class AudiobookSummary {
  const AudiobookSummary({
    required this.id,
    required this.title,
    this.subtitle,
    this.author,
    this.narrator,
    this.series,
    this.duration,
  });

  /// The Audiobookshelf library-item id. Not shown; it is the handle the
  /// later playback work will open the book with.
  final String id;

  final String title;
  final String? subtitle;
  final String? author;
  final String? narrator;
  final String? series;

  /// Total running time, when the server reported one.
  final Duration? duration;
}

/// One library the user can browse, reduced to what the picker shows.
class AudiobookLibrarySummary {
  const AudiobookLibrarySummary({required this.id, required this.name});

  final String id;
  final String name;
}

/// Immutable snapshot the audiobook browser renders from.
///
/// Security: like the connection state, this holds no secret. The session and
/// its tokens stay behind the controller; only display-safe values live here.
class AudiobooksLibraryState {
  const AudiobooksLibraryState({
    this.isConnected = false,
    this.hasLoaded = false,
    this.isLoading = false,
    this.isLoadingMore = false,
    this.libraries = const <AudiobookLibrarySummary>[],
    this.selectedLibraryId,
    this.books = const <AudiobookSummary>[],
    this.totalBooks = 0,
    this.hasMore = false,
    this.errorMessage,
    this.errorKind,
  });

  /// Whether an Audiobookshelf session exists at all. False means the screen
  /// offers the connection instead of an empty list.
  final bool isConnected;

  /// Whether a listing attempt has finished. Separates "nothing yet" from
  /// "this library really is empty", which look identical otherwise.
  final bool hasLoaded;

  /// True while the first page (or a refresh) is in flight.
  final bool isLoading;

  /// True while a further page is being appended, so the list stays on screen
  /// and only its footer shows progress.
  final bool isLoadingMore;

  /// The book libraries this account can see.
  final List<AudiobookLibrarySummary> libraries;

  /// Which of [libraries] is being shown.
  final String? selectedLibraryId;

  /// The books loaded so far, in the server's title order.
  final List<AudiobookSummary> books;

  /// How many books the selected library holds in total, per the server.
  final int totalBooks;

  /// Whether the server still has pages this list hasn't read.
  ///
  /// Reported by the controller from how many entries the server actually
  /// sent, not derived from [books] against [totalBooks]: a page whose every
  /// record was unreadable leaves those two disagreeing forever, and reading
  /// exhaustion off them would either loop or strand the rest of the library.
  final bool hasMore;

  /// A friendly error line, when the last attempt failed.
  final String? errorMessage;

  /// The kind of that failure, for the UI to branch on without matching text.
  final AudiobookshelfErrorKind? errorKind;

  AudiobooksLibraryState copyWith({
    bool? isConnected,
    bool? hasLoaded,
    bool? isLoading,
    bool? isLoadingMore,
    List<AudiobookLibrarySummary>? libraries,
    String? selectedLibraryId,
    List<AudiobookSummary>? books,
    int? totalBooks,
    bool? hasMore,
    String? errorMessage,
    AudiobookshelfErrorKind? errorKind,
  }) {
    return AudiobooksLibraryState(
      isConnected: isConnected ?? this.isConnected,
      hasLoaded: hasLoaded ?? this.hasLoaded,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      libraries: libraries ?? this.libraries,
      selectedLibraryId: selectedLibraryId ?? this.selectedLibraryId,
      books: books ?? this.books,
      totalBooks: totalBooks ?? this.totalBooks,
      hasMore: hasMore ?? this.hasMore,
      // Errors are cleared explicitly rather than carried: every copyWith
      // that doesn't pass one is starting a fresh attempt, and a stale
      // failure must not sit under a list that has since loaded.
      errorMessage: errorMessage,
      errorKind: errorKind,
    );
  }
}
