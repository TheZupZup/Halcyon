import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/platform/host_platform.dart';
import '../../../core/sources/local/android_media_library.dart';
import '../../../core/sources/local/folder_location.dart';
import '../../../core/sources/local/local_scan_report.dart';
import '../../../data/repositories/host_platform_provider.dart';
import '../../library/library_providers.dart';
import '../../library/local_scan_report_provider.dart';
import '../../library/selected_folder_controller.dart';
import 'local_music_controller.dart';

/// Settings home for music already stored on the device.
///
/// Android deliberately exposes two privacy levels: the normal system-visible
/// Music and audio permission for a device-wide MediaStore scan, or a targeted
/// SAF folder grant. The UI names both so no local access is a "ghost" setting.
class LocalMusicSettingsSection extends ConsumerWidget {
  const LocalMusicSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final String? folder =
        ref.watch(selectedFolderControllerProvider).valueOrNull;
    final LocalScanReport? report = ref.watch(localScanReportProvider);
    final LocalMusicActionState action =
        ref.watch(localMusicControllerProvider);
    final bool? persisted = ref.watch(localFolderAccessProvider).valueOrNull;
    final bool hasFolder = folder != null && folder.isNotEmpty;
    final HostPlatform host = ref.watch(hostPlatformProvider);
    final FolderLocation? location =
        hasFolder ? FolderLocation.parse(folder) : null;
    final AndroidMusicPermissionStatus? musicPermission = host.isAndroid
        ? ref.watch(androidMusicPermissionStatusProvider).valueOrNull
        : null;
    final LocalMusicController controller =
        ref.read(localMusicControllerProvider.notifier);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.folder_special_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Text('Local music', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              _blurbFor(host),
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
            if (host.isAndroid) ...[
              const SizedBox(height: AppSpacing.md),
              _AndroidPrivacyStatus(
                permission: musicPermission,
                location: location,
                onOpenSettings: controller.openAndroidPermissions,
                onRefresh: controller.refreshAndroidPermissionStatus,
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            if (hasFolder)
              _SelectedFolderView(
                folderLabel: location!.displayLabel,
                persisted: persisted,
                report: report,
                host: host,
                isDeviceLibrary: location.isAndroidMediaStore,
              )
            else
              Text(
                'No local music source selected yet.',
                style: theme.textTheme.bodyMedium?.copyWith(color: muted),
              ),
            const SizedBox(height: AppSpacing.md),
            if (action.busy)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
                child: Center(
                  child: SizedBox.square(
                    dimension: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else if (hasFolder)
              _FolderActions(
                onRescan: controller.rescan,
                onChange: controller.pickFolder,
                onForget: controller.forget,
                onUseAllDeviceMusic:
                    host.isAndroid && !location!.isAndroidMediaStore
                        ? controller.useAllDeviceMusic
                        : null,
                host: host,
              )
            else if (host.isAndroid)
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton.icon(
                    onPressed: controller.useAllDeviceMusic,
                    icon: const Icon(Icons.library_music_outlined),
                    label: const Text('All music on this device'),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  OutlinedButton.icon(
                    onPressed: controller.pickFolder,
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text('Select a folder'),
                  ),
                ],
              )
            else
              FilledButton.icon(
                onPressed: controller.pickFolder,
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('Select a folder'),
              ),
            if (action.message != null) ...[
              const SizedBox(height: AppSpacing.sm),
              _StatusLine(message: action.message!, isError: action.isError),
            ],
          ],
        ),
      ),
    );
  }
}

String _blurbFor(HostPlatform host) {
  if (host.isAndroid) {
    return 'Choose all music on this device to use Android’s visible Music and '
        'audio permission, or select one folder for narrower Android folder '
        'access. Linthra never requests All files access.';
  }
  return 'Play music from a folder on this computer or an external drive. '
      'Linthra reads only the folder you choose in the system file chooser — '
      'it needs no broad filesystem permission, and your files are never '
      'moved or copied.';
}

class _AndroidPrivacyStatus extends StatelessWidget {
  const _AndroidPrivacyStatus({
    required this.permission,
    required this.location,
    required this.onOpenSettings,
    required this.onRefresh,
  });

  final AndroidMusicPermissionStatus? permission;
  final FolderLocation? location;
  final VoidCallback onOpenSettings;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Privacy & permissions', style: theme.textTheme.titleSmall),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Music and audio: ${_permissionLabel(permission)}',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              _accessExplanation(location),
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: AppSpacing.xs),
            Wrap(
              spacing: AppSpacing.sm,
              children: [
                TextButton(
                  onPressed: onOpenSettings,
                  child: const Text('Android settings'),
                ),
                TextButton(
                  onPressed: onRefresh,
                  child: const Text('Refresh status'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _permissionLabel(AndroidMusicPermissionStatus? status) {
    switch (status) {
      case AndroidMusicPermissionStatus.allowed:
        return 'Allowed';
      case AndroidMusicPermissionStatus.denied:
        return 'Denied';
      case AndroidMusicPermissionStatus.notRequested:
        return 'Not requested';
      case AndroidMusicPermissionStatus.unavailable:
        return 'Unavailable';
      case null:
        return 'Checking…';
    }
  }

  static String _accessExplanation(FolderLocation? location) {
    if (location?.isAndroidMediaStore ?? false) {
      return 'Local library mode: all device music through Android MediaStore. '
          'Revoking Music and audio access stops this scan.';
    }
    if (location?.isContentUri ?? false) {
      return 'Selected folder: targeted Storage Access Framework grant. This '
          'folder grant may not appear as a normal Android runtime permission.';
    }
    return 'Device-wide access is requested only if you choose All music on '
        'this device. Folder access stays targeted and separate.';
  }
}

class _SelectedFolderView extends StatelessWidget {
  const _SelectedFolderView({
    required this.folderLabel,
    required this.persisted,
    required this.report,
    required this.host,
    required this.isDeviceLibrary,
  });

  final String folderLabel;
  final bool? persisted;
  final LocalScanReport? report;
  final HostPlatform host;
  final bool isDeviceLibrary;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              isDeviceLibrary
                  ? Icons.library_music_outlined
                  : Icons.folder_outlined,
              size: 20,
              color: muted,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                folderLabel,
                style: theme.textTheme.bodyMedium,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        if (persisted == false) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            isDeviceLibrary
                ? 'Music and audio access is currently off. Your indexed '
                    'library stays in Linthra; re-enable access to rescan.'
                : 'Linthra can no longer reach this folder. Select it again to '
                    'restore access — your library stays as it is until you do.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.error),
          ),
        ],
        if (report != null) ...[
          const SizedBox(height: AppSpacing.sm),
          _ScanSummary(report: report!, host: host),
        ],
      ],
    );
  }
}

class _ScanSummary extends StatelessWidget {
  const _ScanSummary({required this.report, required this.host});

  final LocalScanReport report;
  final HostPlatform host;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final String? counts = report.hadError ? null : _counts(report);
    final String? hint = _hint(report, host);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_headline(report), style: theme.textTheme.bodyMedium),
        if (counts != null) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            counts,
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ],
        if (hint != null) ...[
          const SizedBox(height: AppSpacing.xs),
          _ScanHintLine(message: hint),
        ],
      ],
    );
  }

  static String _headline(LocalScanReport report) {
    if (report.hadError) return "Last scan couldn't finish";
    if (report.importedTracks > 0) {
      final String word = report.importedTracks == 1 ? 'track' : 'tracks';
      return 'Last scan: ${report.importedTracks} $word added';
    }
    return 'Last scan: no tracks found';
  }

  static String _counts(LocalScanReport report) {
    final List<String> parts = <String>[
      if (report.foldersVisited > 0)
        '${report.foldersVisited} '
            '${report.foldersVisited == 1 ? 'folder' : 'folders'}',
      '${report.filesVisited} ${report.filesVisited == 1 ? 'file' : 'files'}',
      '${report.audioCandidates} audio',
    ];
    if (report.skippedUnsupported > 0) {
      parts.add('${report.skippedUnsupported} skipped');
    }
    if (report.readFailures > 0) {
      parts.add('${report.readFailures} unreadable');
    }
    return parts.join(' · ');
  }

  static String? _hint(LocalScanReport report, HostPlatform host) {
    if (report.importedTracks > 0) return null;
    if (report.error == LocalScanError.mediaPermission) {
      return 'Music and audio access is off. Re-enable it in Android settings '
          'or select a folder instead.';
    }
    final bool blocked = report.hadError ||
        report.readFailures > 0 ||
        (report.isContentUri && report.filesVisited == 0);
    if (blocked) {
      final String sdNote =
          report.isContentUri ? ' — common with SD cards' : '';
      return "Linthra couldn't read this folder$sdNote. Select it again with "
          '${_chooserName(host)} to restore access.';
    }
    return "This folder doesn't seem to contain audio Linthra recognizes. Check "
        'that it has supported audio files (like MP3, M4A, FLAC, or OGG), or '
        'select the folder again with ${_chooserName(host)}.';
  }

  static String _chooserName(HostPlatform host) =>
      host.isAndroid ? "Android's folder chooser" : 'the system folder chooser';
}

class _ScanHintLine extends StatelessWidget {
  const _ScanHintLine({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            message,
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ),
      ],
    );
  }
}

class _FolderActions extends StatelessWidget {
  const _FolderActions({
    required this.onRescan,
    required this.onChange,
    required this.onForget,
    required this.host,
    this.onUseAllDeviceMusic,
  });

  final VoidCallback onRescan;
  final VoidCallback onChange;
  final VoidCallback onForget;
  final VoidCallback? onUseAllDeviceMusic;
  final HostPlatform host;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (onUseAllDeviceMusic != null) ...[
          FilledButton.icon(
            onPressed: onUseAllDeviceMusic,
            icon: const Icon(Icons.library_music_outlined),
            label: const Text('All music on this device'),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        Row(
          children: [
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: onRescan,
                icon: const Icon(Icons.refresh),
                label: const Text('Rescan'),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: onChange,
                icon: const Icon(Icons.folder_open_outlined),
                label: Text(host.isAndroid ? 'Use a folder' : 'Change'),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: onForget,
            icon: const Icon(Icons.delete_outline, size: 18),
            label: const Text('Forget local music'),
          ),
        ),
      ],
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.message, required this.isError});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color color =
        isError ? theme.colorScheme.error : theme.colorScheme.primary;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          isError ? Icons.error_outline : Icons.info_outline,
          size: 18,
          color: color,
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            message,
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}
