package io.github.thezupzup.linthra

import android.os.Handler
import android.os.Looper
import java.util.concurrent.Executor
import java.util.concurrent.Executors

/**
 * Runs one piece of blocking method-channel work off the platform thread and
 * delivers its outcome back on the platform thread.
 *
 * Flutter invokes a `MethodChannel` handler on the platform (main) thread and
 * requires `MethodChannel.Result` to be answered there too. Doing the work
 * *inside* the handler therefore blocks the UI for as long as it takes — fine
 * for reading a flag, not fine for walking a music library through the content
 * resolver (#346). This is the seam between the two: [submit] hands the work to
 * a background thread and posts exactly one callback back to the main looper.
 *
 * The background executor is a single shared daemon thread, deliberately:
 *
 *  * two scans of the same tree at once would only make the content resolver
 *    slower and could double the artwork extraction work, so they queue instead;
 *  * one long-lived thread costs nothing between scans, and a scan started just
 *    before the process dies cannot hold it open.
 *
 * Both executors are injectable so the threading boundary can be exercised
 * without a device. Production takes the defaults.
 */
class PlatformChannelWorker(
    private val background: Executor = SHARED_BACKGROUND,
    private val platform: Executor = PlatformThreadExecutor,
) {

    /**
     * Runs [work] on the background executor, then calls exactly one of
     * [onSuccess] or [onFailure] on the platform thread.
     *
     * Only [Exception] is caught. An [Error] (an OOM on a very large library,
     * say) is left to the default handler rather than being reported as an
     * ordinary channel failure the Dart side would treat as "this folder is
     * unreadable".
     */
    fun <T> submit(
        work: () -> T,
        onSuccess: (T) -> Unit,
        onFailure: (Exception) -> Unit,
    ) {
        background.execute {
            val value =
                try {
                    work()
                } catch (e: Exception) {
                    platform.execute { onFailure(e) }
                    return@execute
                }
            platform.execute { onSuccess(value) }
        }
    }

    /** Posts to the main looper, which is where Flutter wants channel replies. */
    private object PlatformThreadExecutor : Executor {
        private val handler = Handler(Looper.getMainLooper())

        override fun execute(command: Runnable) {
            handler.post(command)
        }
    }

    companion object {
        private val SHARED_BACKGROUND: Executor =
            Executors.newSingleThreadExecutor { runnable ->
                Thread(runnable, "linthra-channel-work").apply { isDaemon = true }
            }
    }
}
