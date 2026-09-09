import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/audiobookshelf_session.dart';
import 'package:linthra/core/repositories/audiobookshelf_session_store.dart';
import 'package:linthra/core/sources/audiobookshelf/audiobookshelf_api.dart';
import 'package:linthra/core/sources/audiobookshelf/audiobookshelf_exception.dart';
import 'package:linthra/data/repositories/audiobookshelf_session_store_provider.dart';
import 'package:linthra/data/repositories/in_memory_audiobookshelf_session_store.dart';
import 'package:linthra/features/audiobooks/audiobooks_library_controller.dart';
import 'package:linthra/features/audiobooks/audiobooks_library_state.dart';
import 'package:linthra/features/settings/audiobookshelf/audiobookshelf_settings_controller.dart';
import 'package:linthra/features/settings/audiobookshelf/audiobookshelf_settings_providers.dart';

import '../../core/sources/audiobookshelf/fake_audiobookshelf_client.dart';

const _session = AudiobookshelfSession(
  baseUrl: 'https://audiobooks.example.com',
  userId: 'user-1',
  accessToken: 'tok-1',
  userName: 'alice',
  defaultLibraryId: 'lib-books',
);

const _bookLibrary = AudiobookshelfLibraryDto(
  id: 'lib-books',
  name: 'Audiobooks',
  mediaType: 'book',
);

const _otherBookLibrary = AudiobookshelfLibraryDto(
  id: 'lib-kids',
  name: 'Kids',
  mediaType: 'book',
);

const _podcastLibrary = AudiobookshelfLibraryDto(
  id: 'lib-pods',
  name: 'Podcasts',
  mediaType: 'podcast',
);

AudiobookshelfLibraryItemDto _book(String id, String title) =>
    AudiobookshelfLibraryItemDto(
      id: id,
      title: title,
      authorName: 'An Author',
      duration: const Duration(hours: 9, minutes: 12),
    );

List<AudiobookshelfLibraryItemDto> _books(int count) =>
    <AudiobookshelfLibraryItemDto>[
      for (int i = 0; i < count; i++) _book('item-$i', 'Book $i'),
    ];

ProviderContainer _container({
  required FakeAudiobookshelfClient client,
  AudiobookshelfSessionStore? store,
}) {
  final container = ProviderContainer(
    overrides: <Override>[
      audiobookshelfClientProvider.overrideWithValue(client),
      audiobookshelfSessionStoreProvider.overrideWithValue(
        store ?? InMemoryAudiobookshelfSessionStore(initialSession: _session),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// A container whose Audiobookshelf connection is signed out.
ProviderContainer _signedOutContainer(FakeAudiobookshelfClient client) =>
    _container(
      client: client,
      store: InMemoryAudiobookshelfSessionStore(),
    );

void main() {
  group('load', () {
    test('offers the connection when no server is signed in', () async {
      final client = FakeAudiobookshelfClient();
      final container = _signedOutContainer(client);

      await container.read(audiobooksLibraryControllerProvider.notifier).load();

      final AudiobooksLibraryState state =
          container.read(audiobooksLibraryControllerProvider);
      expect(state.isConnected, isFalse);
      expect(state.books, isEmpty);
      // Nothing was asked of the server without a session.
      expect(client.itemRequests, isEmpty);
    });

    test('lists the first page of the default library', () async {
      final client = FakeAudiobookshelfClient(
        libraries: <AudiobookshelfLibraryDto>[
          _otherBookLibrary,
          _bookLibrary,
        ],
      );
      client.itemsByLibrary['lib-books'] = <AudiobookshelfLibraryItemDto>[
        _book('item-1', 'The Hobbit'),
      ];
      final container = _container(client: client);

      await container.read(audiobooksLibraryControllerProvider.notifier).load();

      final AudiobooksLibraryState state =
          container.read(audiobooksLibraryControllerProvider);
      expect(state.isConnected, isTrue);
      expect(state.hasLoaded, isTrue);
      expect(state.isLoading, isFalse);
      // The account's default library wins over "the first one listed".
      expect(state.selectedLibraryId, 'lib-books');
      expect(state.books.single.title, 'The Hobbit');
      expect(state.books.single.author, 'An Author');
      expect(
          state.books.single.duration, const Duration(hours: 9, minutes: 12));
      expect(state.hasMore, isFalse);
      expect(
        client.itemRequests.single,
        (
          libraryId: 'lib-books',
          limit: AudiobooksLibraryController.pageSize,
          page: 0,
        ),
      );
    });

    test('leaves podcast libraries out of the audiobook browser', () async {
      final client = FakeAudiobookshelfClient(
        libraries: <AudiobookshelfLibraryDto>[_podcastLibrary, _bookLibrary],
      );
      final container = _container(client: client);

      await container.read(audiobooksLibraryControllerProvider.notifier).load();

      final AudiobooksLibraryState state =
          container.read(audiobooksLibraryControllerProvider);
      expect(
        state.libraries.map((AudiobookLibrarySummary l) => l.id),
        <String>['lib-books'],
      );
    });

    test('keeps a library that reports no media type', () async {
      // An older or unusual server that doesn't send mediaType must not leave
      // the browser looking empty.
      final client = FakeAudiobookshelfClient(
        libraries: const <AudiobookshelfLibraryDto>[
          AudiobookshelfLibraryDto(id: 'lib-x', name: 'Books'),
        ],
      );
      final container = _container(client: client);

      await container.read(audiobooksLibraryControllerProvider.notifier).load();

      expect(
        container.read(audiobooksLibraryControllerProvider).selectedLibraryId,
        'lib-x',
      );
    });

    test('says so when the account has no book library', () async {
      final client = FakeAudiobookshelfClient(
        libraries: <AudiobookshelfLibraryDto>[_podcastLibrary],
      );
      final container = _container(client: client);

      await container.read(audiobooksLibraryControllerProvider.notifier).load();

      final AudiobooksLibraryState state =
          container.read(audiobooksLibraryControllerProvider);
      expect(state.isConnected, isTrue);
      expect(state.hasLoaded, isTrue);
      expect(state.libraries, isEmpty);
      expect(state.errorMessage, isNull);
      expect(client.itemRequests, isEmpty);
    });

    test('surfaces a failed listing without dropping the connection', () async {
      final client = FakeAudiobookshelfClient(
        libraries: <AudiobookshelfLibraryDto>[_bookLibrary],
        libraryItemsError: AudiobookshelfException.serverError(502),
      );
      final container = _container(client: client);

      await container.read(audiobooksLibraryControllerProvider.notifier).load();

      final AudiobooksLibraryState state =
          container.read(audiobooksLibraryControllerProvider);
      expect(state.isConnected, isTrue);
      expect(state.isLoading, isFalse);
      expect(state.errorMessage, contains('HTTP 502'));
      expect(state.errorKind, AudiobookshelfErrorKind.serverError);
    });

    test('a second load keeps what is there, a refresh re-fetches', () async {
      final client = FakeAudiobookshelfClient(
        libraries: <AudiobookshelfLibraryDto>[_bookLibrary],
      );
      client.itemsByLibrary['lib-books'] = _books(2);
      final container = _container(client: client);
      final AudiobooksLibraryController controller =
          container.read(audiobooksLibraryControllerProvider.notifier);

      await controller.load();
      await controller.load();
      expect(client.itemRequests, hasLength(1));

      await controller.refresh();
      expect(client.itemRequests, hasLength(2));
      expect(
        container.read(audiobooksLibraryControllerProvider).books,
        hasLength(2),
      );
    });

    test('a retry after a failure re-fetches without asking for a refresh',
        () async {
      final client = FakeAudiobookshelfClient(
        libraries: <AudiobookshelfLibraryDto>[_bookLibrary],
        libraryItemsError: AudiobookshelfException.serverError(500),
      );
      client.itemsByLibrary['lib-books'] = _books(1);
      final container = _container(client: client);
      final AudiobooksLibraryController controller =
          container.read(audiobooksLibraryControllerProvider.notifier);

      await controller.load();
      expect(
        container.read(audiobooksLibraryControllerProvider).errorMessage,
        isNotNull,
      );

      client.libraryItemsError = null;
      await controller.load();

      final AudiobooksLibraryState state =
          container.read(audiobooksLibraryControllerProvider);
      expect(state.errorMessage, isNull);
      expect(state.books, hasLength(1));
    });
  });

  group('a different account', () {
    test('never shows the previous account its books or library names',
        () async {
      final client = FakeAudiobookshelfClient(
        serverStatus: const AudiobookshelfServerStatus(
          serverVersion: '2.17.0',
          isInitialized: true,
        ),
        authResult: const AudiobookshelfAuthResult(
          userId: 'user-2',
          accessToken: 'tok-2',
          userName: 'bob',
          defaultLibraryId: 'lib-bob',
        ),
        libraries: <AudiobookshelfLibraryDto>[_bookLibrary],
      );
      client.itemsByLibrary['lib-books'] = <AudiobookshelfLibraryItemDto>[
        _book('item-1', 'Alice only'),
      ];
      final container = _container(client: client);
      final AudiobooksLibraryController controller =
          container.read(audiobooksLibraryControllerProvider.notifier);
      final AudiobookshelfSettingsController connection =
          container.read(audiobookshelfSettingsControllerProvider.notifier);

      await controller.load();
      expect(
        container.read(audiobooksLibraryControllerProvider).books.single.title,
        'Alice only',
      );

      // Sign out, then sign in as somebody else on the same device.
      await connection.clear();
      client.libraries = const <AudiobookshelfLibraryDto>[
        AudiobookshelfLibraryDto(
          id: 'lib-bob',
          name: "Bob's books",
          mediaType: 'book',
        ),
      ];
      client.itemsByLibrary['lib-bob'] = <AudiobookshelfLibraryItemDto>[
        _book('item-9', 'Bob only'),
      ];
      await connection.signIn(
        url: 'https://audiobooks.example.com',
        username: 'bob',
        password: 'hunter2',
      );

      // No force: the screen just being reopened must still re-fetch.
      await controller.load();

      final AudiobooksLibraryState state =
          container.read(audiobooksLibraryControllerProvider);
      expect(state.books.single.title, 'Bob only');
      expect(state.selectedLibraryId, 'lib-bob');
      expect(
        state.libraries.map((AudiobookLibrarySummary l) => l.name),
        <String>["Bob's books"],
      );
    });

    test('a sign-out empties the browser', () async {
      final client = FakeAudiobookshelfClient(
        libraries: <AudiobookshelfLibraryDto>[_bookLibrary],
      );
      client.itemsByLibrary['lib-books'] = _books(1);
      final container = _container(client: client);
      final AudiobooksLibraryController controller =
          container.read(audiobooksLibraryControllerProvider.notifier);

      await controller.load();
      await container
          .read(audiobookshelfSettingsControllerProvider.notifier)
          .clear();
      await controller.load();

      final AudiobooksLibraryState state =
          container.read(audiobooksLibraryControllerProvider);
      expect(state.isConnected, isFalse);
      expect(state.books, isEmpty);
      expect(state.libraries, isEmpty);
    });
  });

  group('selectLibrary', () {
    test('switches library and replaces the list', () async {
      final client = FakeAudiobookshelfClient(
        libraries: <AudiobookshelfLibraryDto>[_bookLibrary, _otherBookLibrary],
      );
      client.itemsByLibrary['lib-books'] = _books(3);
      client.itemsByLibrary['lib-kids'] = <AudiobookshelfLibraryItemDto>[
        _book('kid-1', 'Matilda'),
      ];
      final container = _container(client: client);
      final AudiobooksLibraryController controller =
          container.read(audiobooksLibraryControllerProvider.notifier);

      await controller.load();
      await controller.selectLibrary('lib-kids');

      final AudiobooksLibraryState state =
          container.read(audiobooksLibraryControllerProvider);
      expect(state.selectedLibraryId, 'lib-kids');
      expect(state.books.single.title, 'Matilda');
      expect(state.totalBooks, 1);
    });

    test('picking the library already open asks the server for nothing',
        () async {
      final client = FakeAudiobookshelfClient(
        libraries: <AudiobookshelfLibraryDto>[_bookLibrary],
      );
      client.itemsByLibrary['lib-books'] = _books(1);
      final container = _container(client: client);
      final AudiobooksLibraryController controller =
          container.read(audiobooksLibraryControllerProvider.notifier);

      await controller.load();
      await controller.selectLibrary('lib-books');

      expect(client.itemRequests, hasLength(1));
    });

    test('a refresh keeps the library the user picked', () async {
      final client = FakeAudiobookshelfClient(
        libraries: <AudiobookshelfLibraryDto>[_bookLibrary, _otherBookLibrary],
      );
      client.itemsByLibrary['lib-kids'] = <AudiobookshelfLibraryItemDto>[
        _book('kid-1', 'Matilda'),
      ];
      final container = _container(client: client);
      final AudiobooksLibraryController controller =
          container.read(audiobooksLibraryControllerProvider.notifier);

      await controller.load();
      await controller.selectLibrary('lib-kids');
      await controller.refresh();

      expect(
        container.read(audiobooksLibraryControllerProvider).selectedLibraryId,
        'lib-kids',
      );
    });
  });

  group('loadMore', () {
    test('appends the next page and then stops offering one', () async {
      const int pageSize = AudiobooksLibraryController.pageSize;
      final client = FakeAudiobookshelfClient(
        libraries: <AudiobookshelfLibraryDto>[_bookLibrary],
      );
      client.itemsByLibrary['lib-books'] = _books(pageSize + 5);
      final container = _container(client: client);
      final AudiobooksLibraryController controller =
          container.read(audiobooksLibraryControllerProvider.notifier);

      await controller.load();
      expect(
        container.read(audiobooksLibraryControllerProvider).books,
        hasLength(pageSize),
      );
      expect(
        container.read(audiobooksLibraryControllerProvider).hasMore,
        isTrue,
      );

      await controller.loadMore();

      final AudiobooksLibraryState state =
          container.read(audiobooksLibraryControllerProvider);
      expect(state.books, hasLength(pageSize + 5));
      expect(state.hasMore, isFalse);
      expect(state.isLoadingMore, isFalse);
      expect(client.itemRequests.last.page, 1);

      // Nothing left to ask for.
      await controller.loadMore();
      expect(client.itemRequests, hasLength(2));
    });

    test('switching library mid-page leaves no spinner behind', () async {
      const int pageSize = AudiobooksLibraryController.pageSize;
      final client = FakeAudiobookshelfClient(
        libraries: <AudiobookshelfLibraryDto>[_bookLibrary, _otherBookLibrary],
      );
      client.itemsByLibrary['lib-books'] = _books(pageSize + 5);
      client.itemsByLibrary['lib-kids'] = <AudiobookshelfLibraryItemDto>[
        _book('kid-1', 'Matilda'),
      ];
      final container = _container(client: client);
      final AudiobooksLibraryController controller =
          container.read(audiobooksLibraryControllerProvider.notifier);

      await controller.load();

      // The next page of the first library is still in flight when the user
      // picks another one.
      final Future<void> pending = controller.loadMore();
      final Future<void> switched = controller.selectLibrary('lib-kids');
      await Future.wait(<Future<void>>[pending, switched]);

      final AudiobooksLibraryState state =
          container.read(audiobooksLibraryControllerProvider);
      expect(state.selectedLibraryId, 'lib-kids');
      expect(state.books.single.title, 'Matilda');
      // The abandoned page must not leave the footer spinning, which would
      // also block every later page.
      expect(state.isLoadingMore, isFalse);
    });

    test('a failed page keeps the books already on screen', () async {
      const int pageSize = AudiobooksLibraryController.pageSize;
      final client = FakeAudiobookshelfClient(
        libraries: <AudiobookshelfLibraryDto>[_bookLibrary],
      );
      client.itemsByLibrary['lib-books'] = _books(pageSize + 1);
      final container = _container(client: client);
      final AudiobooksLibraryController controller =
          container.read(audiobooksLibraryControllerProvider.notifier);

      await controller.load();
      client.libraryItemsError = AudiobookshelfException.notReachable();
      await controller.loadMore();

      final AudiobooksLibraryState state =
          container.read(audiobooksLibraryControllerProvider);
      expect(state.books, hasLength(pageSize));
      expect(state.isLoadingMore, isFalse);
      expect(state.errorMessage, isNotNull);
      // Still offered: the page can be retried.
      expect(state.hasMore, isTrue);
    });
  });
}
