package io.github.thezupzup.linthra

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Exposes Android's install/update timestamps so v0.2.0 can distinguish a true
 * first install from an existing Linthra installation receiving an update.
 *
 * No identifiers or package list leave the device; only this app's own two
 * timestamps are returned. That lets onboarding stay first-install-only even
 * for users who never configured a music source in an older release.
 */
class InstallHistoryChannel(private val context: Context) {
    fun configure(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getInstallHistory" -> {
                    try {
                        @Suppress("DEPRECATION")
                        val info = context.packageManager.getPackageInfo(context.packageName, 0)
                        result.success(
                            mapOf(
                                "firstInstallTime" to info.firstInstallTime,
                                "lastUpdateTime" to info.lastUpdateTime,
                            ),
                        )
                    } catch (error: Exception) {
                        result.error("install_history", error.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    companion object {
        const val CHANNEL = "io.github.thezupzup.linthra/install_history"
    }
}
