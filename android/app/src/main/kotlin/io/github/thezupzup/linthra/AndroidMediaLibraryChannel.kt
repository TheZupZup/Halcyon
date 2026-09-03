package io.github.thezupzup.linthra

import android.Manifest
import android.app.Activity
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Android's device-wide local-music integration.
 *
 * This is intentionally separate from SAF folder access. The user opts into the
 * normal Android "Music and audio" permission for a MediaStore-wide scan, or can
 * keep using the existing folder picker for a targeted persisted grant. This
 * class never requests MANAGE_EXTERNAL_STORAGE, photo, or video access.
 */
class AndroidMediaLibraryChannel(private val activity: Activity) {
    private val context: Context = activity.applicationContext

    fun configure(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            handle(call, result)
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "permissionStatus" -> result.success(permissionStatus())
            "requestPermission" -> requestPermission(result)
            "openAppSettings" -> openAppSettings(result)
            "listDeviceAudio" -> listDeviceAudio(result)
            else -> result.notImplemented()
        }
    }

    private fun permissionStatus(): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return STATUS_ALLOWED
        if (activity.checkSelfPermission(readPermission()) == PackageManager.PERMISSION_GRANTED) {
            return STATUS_ALLOWED
        }
        val requested = context
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(KEY_REQUESTED, false)
        return if (requested) STATUS_DENIED else STATUS_NOT_REQUESTED
    }

    private fun requestPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            permissionStatus() == STATUS_ALLOWED
        ) {
            result.success(STATUS_ALLOWED)
            return
        }
        if (pendingPermissionResult != null) {
            result.error(
                "permission_in_progress",
                "A music permission request is already in progress.",
                null,
            )
            return
        }

        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_REQUESTED, true)
            .apply()
        pendingPermissionResult = result
        activity.requestPermissions(arrayOf(readPermission()), REQUEST_CODE_PERMISSION)
    }

    fun onRequestPermissionsResult(
        requestCode: Int,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQUEST_CODE_PERMISSION) return false
        val result = pendingPermissionResult
        pendingPermissionResult = null
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        result?.success(if (granted) STATUS_ALLOWED else STATUS_DENIED)
        return true
    }

    private fun openAppSettings(result: MethodChannel.Result) {
        try {
            val intent = Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", context.packageName, null),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            result.success(null)
        } catch (e: Exception) {
            result.error("settings_unavailable", "Android app settings are unavailable.", null)
        }
    }

    private fun listDeviceAudio(result: MethodChannel.Result) {
        if (permissionStatus() != STATUS_ALLOWED) {
            result.error(
                "permission_denied",
                "Music and audio permission is not granted.",
                null,
            )
            return
        }

        Thread({
            try {
                val documents = queryDeviceAudio()
                activity.runOnUiThread {
                    result.success(
                        mapOf(
                            "documents" to documents,
                            "filesVisited" to documents.size,
                            "foldersVisited" to 0,
                            "readFailures" to 0,
                        ),
                    )
                }
            } catch (e: SecurityException) {
                activity.runOnUiThread {
                    result.error(
                        "permission_denied",
                        "Music and audio permission is not granted.",
                        null,
                    )
                }
            } catch (e: Exception) {
                activity.runOnUiThread {
                    result.error(
                        "media_store_failed",
                        "Android MediaStore could not be read.",
                        null,
                    )
                }
            }
        }, "linthra-media-store-scan").start()
    }

    private fun queryDeviceAudio(): List<Map<String, Any?>> {
        val projection = arrayOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.DISPLAY_NAME,
            MediaStore.Audio.Media.MIME_TYPE,
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM,
            MediaStore.Audio.Media.TRACK,
            MediaStore.Audio.Media.DURATION,
        )
        val documents = ArrayList<Map<String, Any?>>()
        context.contentResolver.query(
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
            projection,
            "${MediaStore.Audio.Media.IS_MUSIC} != 0",
            null,
            "${MediaStore.Audio.Media.TITLE} COLLATE NOCASE ASC",
        )?.use { cursor ->
            val idIndex = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
            val nameIndex = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DISPLAY_NAME)
            val mimeIndex = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.MIME_TYPE)
            val titleIndex = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.TITLE)
            val artistIndex = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.ARTIST)
            val albumIndex = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM)
            val trackIndex = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.TRACK)
            val durationIndex = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DURATION)

            while (cursor.moveToNext()) {
                val id = cursor.getLong(idIndex)
                val title = cleanMediaValue(cursor.getString(titleIndex))
                val name = cleanMediaValue(cursor.getString(nameIndex))
                    ?: title
                    ?: "Audio $id"
                val track = cursor.getInt(trackIndex).takeIf { it > 0 }
                val durationMs = cursor.getLong(durationIndex).takeIf { it > 0L }
                val uri = ContentUris.withAppendedId(
                    MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
                    id,
                )
                documents.add(
                    mapOf(
                        "uri" to uri.toString(),
                        "name" to name,
                        "mime" to cleanMediaValue(cursor.getString(mimeIndex)),
                        "title" to title,
                        "artist" to cleanMediaValue(cursor.getString(artistIndex)),
                        "albumArtist" to null,
                        "album" to cleanMediaValue(cursor.getString(albumIndex)),
                        "track" to track,
                        "durationMs" to durationMs,
                        "artworkUri" to null,
                    ),
                )
            }
        }
        return documents
    }

    private fun cleanMediaValue(value: String?): String? {
        if (value == null) return null
        val trimmed = value.trim()
        if (trimmed.isEmpty() || trimmed == MediaStore.UNKNOWN_STRING) return null
        return trimmed
    }

    private fun readPermission(): String =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Manifest.permission.READ_MEDIA_AUDIO
        } else {
            Manifest.permission.READ_EXTERNAL_STORAGE
        }

    companion object {
        const val CHANNEL = "io.github.thezupzup.linthra/media_library"

        private const val PREFS = "linthra_media_permissions"
        private const val KEY_REQUESTED = "music_audio_permission_requested"
        private const val STATUS_ALLOWED = "allowed"
        private const val STATUS_DENIED = "denied"
        private const val STATUS_NOT_REQUESTED = "notRequested"
        private const val REQUEST_CODE_PERMISSION = 0xA0D1

        // Process-scoped for the same reason as MainActivity's SAF picker reply:
        // a permission dialog may recreate the activity before the callback.
        private var pendingPermissionResult: MethodChannel.Result? = null
    }
}
