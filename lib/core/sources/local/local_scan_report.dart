/// Why the most recent local-folder scan ended the way it did, recorded as a
/// failure *kind* (an enum name) — never a raw error string that could carry a
/// folder path, file name, or device detail.
enum LocalScanError {
  /// The selected folder could not be traversed through Android's Storage
  /// Access Framework (revoked grant, unresolvable provider, unreadable path).
  safTraversal,

  /// Android's device-wide Music and audio / MediaStore access is unavailable
  /// or revoked. This is distinct from SAF because the recovery action is the
  /// normal Android app-permission screen, not re-picking a folder.
  mediaPermission,

  /// The selected folder itself could not be opened on a filesystem scan: it
  /// is missing, unreadable, or (in the Flatpak) the portal document that
  /// exposed it was revoked. Recoverable by reselecting the folder.
  folderUnavailable,

  /// Any other unexpected scan failure (a `dart:io` fault, a plugin error).
  unexpected,
}

/// A secret-free snapshot of the last local-folder scan, so a bug report can
/// show *why* a scan turned up empty without revealing anything private.
class LocalScanReport {
  const LocalScanReport({
    required this.folderSelected,
    required this.isContentUri,
    required this.filesVisited,
    required this.audioCandidates,
    required this.skippedUnsupported,
    required this.readFailures,
    this.foldersVisited = 0,
    this.importedTracks = 0,
    this.recursive = true,
    this.error,
  });

  /// Builds a failure report (all counts zero) from what the caller knows about
  /// the selection — used when the scan threw before producing any counts.
  const LocalScanReport.failure({
    required this.folderSelected,
    required this.isContentUri,
    required LocalScanError this.error,
  })  : filesVisited = 0,
        foldersVisited = 0,
        audioCandidates = 0,
        importedTracks = 0,
        skippedUnsupported = 0,
        readFailures = 0,
        recursive = true;

  final bool folderSelected;
  final bool isContentUri;
  final int filesVisited;
  final int foldersVisited;
  final int audioCandidates;
  final int importedTracks;
  final int skippedUnsupported;
  final int readFailures;
  final bool recursive;
  final LocalScanError? error;

  bool get hadError => error != null;
}
