package io.github.thezupzup.linthra

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

// Reports the app's active Android network as unmetered, metered, offline, or
// unknown. Download policy cares about metering rather than the transport name:
// a paid Wi-Fi hotspot may be metered, while a carrier can temporarily mark a
// cellular connection unmetered. This also lets Android classify the default
// network correctly when a VPN is active.
//
// The channel exposes both a one-shot method and a change stream. It never
// returns an SSID, carrier, IP address, server URL, token, or any other user data.
class NetworkStatusChannel(private val context: Context) : EventChannel.StreamHandler {
    private val connectivityManager =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val mainHandler = Handler(Looper.getMainLooper())

    private var eventSink: EventChannel.EventSink? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var legacyReceiver: BroadcastReceiver? = null
    private var lastStatus: String? = null

    fun configure(messenger: BinaryMessenger) {
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getNetworkStatus" -> result.success(currentStatus())
                else -> result.notImplemented()
            }
        }
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        eventSink = events
        lastStatus = null
        registerForChanges()
        emit(currentStatus())
    }

    override fun onCancel(arguments: Any?) {
        unregisterForChanges()
        eventSink = null
        lastStatus = null
    }

    private fun registerForChanges() {
        if (networkCallback != null || legacyReceiver != null) return

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                val callback = object : ConnectivityManager.NetworkCallback() {
                    override fun onCapabilitiesChanged(
                        network: Network,
                        networkCapabilities: NetworkCapabilities,
                    ) {
                        emit(statusFor(networkCapabilities))
                    }

                    override fun onLost(network: Network) {
                        // A replacement default network may already exist. Read
                        // again on the main loop instead of assuming "offline".
                        mainHandler.post { emit(currentStatus()) }
                    }

                    override fun onUnavailable() {
                        emit(STATUS_OFFLINE)
                    }
                }
                connectivityManager.registerDefaultNetworkCallback(callback)
                networkCallback = callback
            } else {
                @Suppress("DEPRECATION")
                val receiver = object : BroadcastReceiver() {
                    override fun onReceive(context: Context?, intent: Intent?) {
                        emit(currentStatus())
                    }
                }
                @Suppress("DEPRECATION")
                context.registerReceiver(
                    receiver,
                    IntentFilter(ConnectivityManager.CONNECTIVITY_ACTION),
                )
                legacyReceiver = receiver
            }
        } catch (e: SecurityException) {
            // Missing/blocked ACCESS_NETWORK_STATE must fail closed, never as
            // unmetered. The manifest declares it, but unusual devices can still
            // deny platform services.
            emit(STATUS_UNKNOWN)
        } catch (e: RuntimeException) {
            // Android limits registered callbacks. A registration failure stays
            // conservative and exposes no raw platform detail to Dart.
            emit(STATUS_UNKNOWN)
        }
    }

    private fun unregisterForChanges() {
        networkCallback?.let { callback ->
            try {
                connectivityManager.unregisterNetworkCallback(callback)
            } catch (e: IllegalArgumentException) {
                // Already unregistered by the platform; nothing remains to do.
            }
        }
        networkCallback = null

        legacyReceiver?.let { receiver ->
            try {
                context.unregisterReceiver(receiver)
            } catch (e: IllegalArgumentException) {
                // Already unregistered by the platform; nothing remains to do.
            }
        }
        legacyReceiver = null
    }

    private fun currentStatus(): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            @Suppress("DEPRECATION")
            val active = connectivityManager.activeNetworkInfo
                ?: return STATUS_OFFLINE
            @Suppress("DEPRECATION")
            if (!active.isConnected) return STATUS_OFFLINE
            return if (connectivityManager.isActiveNetworkMetered) {
                STATUS_METERED
            } else {
                STATUS_UNMETERED
            }
        }

        val network = connectivityManager.activeNetwork ?: return STATUS_OFFLINE
        val capabilities = connectivityManager.getNetworkCapabilities(network)
            ?: return STATUS_UNKNOWN
        return statusFor(capabilities)
    }

    private fun statusFor(capabilities: NetworkCapabilities): String {
        val unmetered = capabilities.hasCapability(
            NetworkCapabilities.NET_CAPABILITY_NOT_METERED,
        ) || (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
                capabilities.hasCapability(
                    NetworkCapabilities.NET_CAPABILITY_TEMPORARILY_NOT_METERED,
                )
            )
        return if (unmetered) STATUS_UNMETERED else STATUS_METERED
    }

    private fun emit(status: String) {
        mainHandler.post {
            if (status == lastStatus) return@post
            lastStatus = status
            eventSink?.success(status)
        }
    }

    companion object {
        private const val METHOD_CHANNEL =
            "io.github.thezupzup.linthra/network_status"
        private const val EVENT_CHANNEL =
            "io.github.thezupzup.linthra/network_status_events"

        private const val STATUS_UNMETERED = "unmetered"
        private const val STATUS_METERED = "metered"
        private const val STATUS_OFFLINE = "offline"
        private const val STATUS_UNKNOWN = "unknown"
    }
}
