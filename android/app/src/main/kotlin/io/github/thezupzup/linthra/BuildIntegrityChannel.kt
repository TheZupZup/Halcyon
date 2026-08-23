package io.github.thezupzup.linthra

import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.MessageDigest

/**
 * Reports whether the installed APK is signed by Linthra's official release
 * certificate.
 *
 * The trusted value is the public SHA-256 certificate fingerprint already
 * pinned by F-Droid's `AllowedAPKSigningKeys` for Linthra's reproducible build.
 * F-Droid verifies its rebuild against the upstream developer-signed APK and
 * publishes that developer-signed binary only when it matches, so GitHub and
 * F-Droid share the same official signing identity.
 *
 * This does not make an open-source client tamper-proof: a determined fork can
 * remove its own warning code. The check protects users from ordinary APK
 * repackaging and, together with the trademark policy and official download
 * documentation, makes origin explicit.
 */
class BuildIntegrityChannel(private val context: Context) {
    fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "getBuildIntegrity") {
            result.notImplemented()
            return
        }
        result.success(currentStatus())
    }

    private fun currentStatus(): Map<String, String?> {
        return try {
            val digests = currentSignerDigests()
            val debuggable =
                (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
            val status = when {
                debuggable -> "development"
                digests.isNotEmpty() && digests.all { it in OFFICIAL_SIGNING_CERTIFICATES } ->
                    "official"
                digests.isNotEmpty() -> "unofficial"
                else -> "unavailable"
            }
            mapOf(
                "status" to status,
                "certificateSha256" to digests.firstOrNull(),
            )
        } catch (_: Exception) {
            // Do not expose package-manager exception strings to Dart. The app
            // fails closed and shows the generic unverifiable-build warning.
            mapOf(
                "status" to "unavailable",
                "certificateSha256" to null,
            )
        }
    }

    @Suppress("DEPRECATION")
    private fun currentSignerDigests(): List<String> {
        val packageInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            context.packageManager.getPackageInfo(
                context.packageName,
                PackageManager.GET_SIGNING_CERTIFICATES,
            )
        } else {
            context.packageManager.getPackageInfo(
                context.packageName,
                PackageManager.GET_SIGNATURES,
            )
        }

        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            packageInfo.signingInfo?.apkContentsSigners.orEmpty()
        } else {
            packageInfo.signatures.orEmpty()
        }

        return signatures.map { signature ->
            val digest = MessageDigest.getInstance("SHA-256").digest(signature.toByteArray())
            digest.joinToString(separator = "") { byte -> "%02x".format(byte) }
        }
    }

    companion object {
        const val CHANNEL = "io.github.thezupzup.linthra/build_integrity"

        // Public signing-certificate fingerprint, not a secret. Keep this in
        // sync with metadata/io.github.thezupzup.linthra.yml's
        // AllowedAPKSigningKeys if the release key is ever intentionally rotated.
        private val OFFICIAL_SIGNING_CERTIFICATES = setOf(
            "835189ae30df4d23588580e0a86e5e9b67ea2a2745fda510759f22a3d0a78b6c",
        )
    }
}
