package io.github.thezupzup.linthra

import java.util.concurrent.Executor
import java.util.concurrent.Executors

/**
 * Runs one piece of blocking method-channel work off the platform thread and
 * delivers its outcome from that worker thread.
 *
 * Flutter invokes a `MethodChannel` handler on the platform (main) thread.
 * Doing the work *inside* the handler therefore blocks the UI for as long as it
 * takes — fine
 * for reading a flag, not fine for walking a music library through the content
 * resolver (#346). This is the seam between the two: [submit] hands the work to
 * a background thread and invokes exactly one callback there. Flutter permits
 * `MethodChannel.Result` replies from any thread, which also keeps the channel
 * codec's potentially large success-envelope encoding off the platform thread.
 *
 * The background executor is a single shared daemon thread, deliberately:
 *
 *  * two scans of the same tree at once would only make the content resolver
 *    slower and could double the artwork extraction work, so they queue instead;
 *  * one long-lived thread costs nothing between scans, and a scan started just
 *    before the process dies cannot hold it open.
 *
 * The executor is injectable so the threading boundary can be exercised
 * without a device. Production takes the default.
 */
class PlatformChannelWorker(
    private val background: Executor = SHARED_BACKGROUND,
) {

    /**
     * Runs [work] on the background executor, then calls exactly one of
     * [onSuccess] or [onFailure] on that same worker thread.
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
                    onFailure(e)
                    return@execute
                }
            onSuccess(value)
        }
    }

    companion object {
        private val SHARED_BACKGROUND: Executor =
            Executors.newSingleThreadExecutor { runnable ->
                Thread(runnable, "linthra-channel-work").apply { isDaemon = true }
            }
    }
}
