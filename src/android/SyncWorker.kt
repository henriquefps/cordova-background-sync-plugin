package com.hfps.backgroundsync

import android.app.ActivityManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.database.CursorWindow
import net.zetetic.database.sqlcipher.SQLiteCursor
import net.zetetic.database.sqlcipher.SQLiteDatabase
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkInfo
import androidx.work.WorkerParameters
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.DataOutputStream
import java.io.File
import java.io.FileInputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.*
import android.content.ContentValues

class SyncWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {

    private val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private val progressChannelId = "localstorage_sync_progress_channel"
    private val alertsChannelId = "localstorage_sync_alerts_channel"
    private val notificationId = 1002
    private val resultNotificationId = 1003
    private var customTexts = JSONObject()
    private var showDebugLogs = false
    private var enableNotifications = true
    private var syncOnlyOnWifi = true
    private var foregroundActive = false
    private var lastForegroundAttempt = 0L
    private var lastProgressPost = 0L
    private var backgroundStartLogged = false

    companion object {
        private val runLock = Mutex()
        private const val PROGRESS_MIN_INTERVAL_MS = 1000L
        private const val FOREGROUND_RETRY_MS = 5000L
        private const val NETWORK_WAIT_MS = 5 * 60 * 1000L
        private const val NETWORK_POLL_MS = 2000L
        private const val MAX_NETWORK_WAITS_PER_ITEM = 3
    }

    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        // One run at a time per process. A cancelled or replaced worker keeps its thread until
        // the blocking upload in flight returns; without this lock the next run could load the
        // same still-pending record and send it a second time.
        runLock.withLock { runQueues() }
    }

    override suspend fun getForegroundInfo(): ForegroundInfo {
        return createForegroundInfo(createNotificationProgress(0, 0, 0))
    }

    private suspend fun runQueues(): Result {
        val sharedPref = applicationContext.getSharedPreferences(
            BackgroundSyncPlugin.PREFS_NAME,
            Context.MODE_PRIVATE
        )
        showDebugLogs = sharedPref.getBoolean(BackgroundSyncPlugin.KEY_SHOW_DEBUG_LOGS, false)
        val serverUrl = sharedPref.getString(BackgroundSyncPlugin.KEY_SERVER_URL, "") ?: ""
        enableNotifications = sharedPref.getBoolean(BackgroundSyncPlugin.KEY_ENABLE_NOTIFICATIONS, true)
        val autoDeleteCompleted = sharedPref.getBoolean(BackgroundSyncPlugin.KEY_AUTO_DELETE_COMPLETED, false)
        val headersStr = sharedPref.getString(BackgroundSyncPlugin.KEY_HEADERS, "{}") ?: "{}"
        val notificationTextsStr = sharedPref.getString(BackgroundSyncPlugin.KEY_NOTIFICATION_TEXTS, "{}") ?: "{}"
        val encryptDatabase = sharedPref.getBoolean(BackgroundSyncPlugin.KEY_ENCRYPT_DATABASE, false)
        syncOnlyOnWifi = sharedPref.getBoolean(BackgroundSyncPlugin.KEY_SYNC_ONLY_ON_WIFI, true)

        try {
            customTexts = JSONObject(notificationTextsStr)
        } catch (e: Exception) {
            e.printStackTrace()
        }

        if (serverUrl.isEmpty()) {
            return Result.failure()
        }

        // A single connection is opened for the whole worker run — loading both queues,
        // fetching each record's payload, and writing each record's status — instead of
        // re-opening/closing SQLite per record. Re-opening re-runs table-creation/key-derivation
        // work on every open, which added up fast across a queue of dozens of pending records.
        val db: SQLiteDatabase
        try {
            db = DatabaseHelper.getWritableDatabase(applicationContext, encryptDatabase)
            db.rawQuery("PRAGMA busy_timeout = 5000;", null).use { c -> c.moveToFirst() }
        } catch (e: Exception) {
            logE("Failed to open sync database: ${e.message}", e)
            BackgroundSyncPlugin.sendProgressUpdate("failed", 0, 0, 0, e.message)
            return Result.failure()
        }

        try {
            val pendingRecords: MutableList<SyncRecord>
            try {
                pendingRecords = loadPendingRecords(db)
            } catch (e: Exception) {
                logE("Failed to load records from sync queue: ${e.message}", e)
                BackgroundSyncPlugin.sendProgressUpdate("failed", 0, 0, 0, e.message)
                return Result.failure()
            }
            logD("Total queued pending sync records: ${pendingRecords.size}")

            var pendingDownloads: MutableList<DownloadRecord> = mutableListOf()
            try {
                pendingDownloads = loadPendingDownloads(db)
            } catch (e: Exception) {
                logE("Failed to load records from download queue: ${e.message}", e)
            }
            logD("Total queued pending download records: ${pendingDownloads.size}")

            if (pendingRecords.isEmpty() && pendingDownloads.isEmpty()) {
                // Nothing to do. No foreground service and no "complete" notification: this
                // path runs on every enqueueSync with an empty queue (the JS layer calls it on
                // each "online" event), and an alert for zero records is noise.
                return Result.success()
            }

            if (enableNotifications) {
                createNotificationChannel()
                // A new run supersedes the previous run's final notification.
                notificationManager.cancel(resultNotificationId)
                val preparing = createNotificationProgress(0, 0, 0)
                if (!tryPromoteToForeground(preparing)) {
                    postProgressNotification(preparing)
                }
            }

            val uploads = processQueue(
                db, isDownload = false, initial = pendingRecords,
                reload = { loadPendingRecords(it) },
                process = { record -> processUpload(db, record, serverUrl, headersStr, autoDeleteCompleted) }
            )
            if (uploads.outcome != QueueOutcome.DONE) {
                return finishInterrupted(uploads, isDownload = false)
            }

            val downloads = processQueue(
                db, isDownload = true, initial = pendingDownloads,
                reload = { loadPendingDownloads(it) },
                process = { record -> processDownload(db, record, serverUrl, headersStr) }
            )
            if (downloads.outcome != QueueOutcome.DONE) {
                return finishInterrupted(downloads, isDownload = true)
            }

            val total = uploads.total + downloads.total
            val failed = uploads.failed + downloads.failed
            if (enableNotifications) {
                cancelProgressNotification()
                if (failed == 0) {
                    updateNotificationSuccess()
                } else {
                    updateNotificationPartial(failed, total, downloads.lastError ?: uploads.lastError ?: "")
                }
            }
            BackgroundSyncPlugin.sendProgressUpdate("completed", 100, uploads.processed + downloads.processed, total)
            return Result.success()
        } finally {
            db.close()
            if (enableNotifications) {
                // Never leave an ongoing notification behind. When the foreground service is
                // active WorkManager removes its notification itself once the run ends.
                cancelProgressNotification()
            }
        }
    }

    // Final notification and result for a run that did not reach the end of a queue.
    private fun finishInterrupted(run: QueueRun, isDownload: Boolean): Result {
        if (run.outcome == QueueOutcome.STOPPED) {
            val reason = stopReasonCompat()
            logI("Sync worker stopped by WorkManager (stop reason $reason) after ${run.processed} of ${run.total} items.")
            if (enableNotifications) {
                cancelProgressNotification()
                // Cancelled by the app (cancelSync, or enqueueSync replacing the run): no notice.
                // Any other reason (time limit, lost constraint, quota, ...) is a pause: WorkManager
                // runs the work again on its own once the system allows it.
                if (reason != WorkInfo.STOP_REASON_CANCELLED_BY_APP) {
                    updateNotificationPaused(run.processed, run.total, isDownload)
                }
            }
            // WorkManager ignores the result of a stopped worker and reschedules it unless it was cancelled.
            return Result.retry()
        }
        // NETWORK: the request never reached the server. Retry with WorkManager's backoff.
        logI("Sync worker aborted due to transient network error. Rescheduling retry...")
        if (enableNotifications) {
            cancelProgressNotification()
            updateNotificationFailure(run.lastError ?: "", isDownload)
        }
        return Result.retry()
    }

    // Runs one queue (uploads or downloads) to the end, picking up records enqueued while the
    // run is in progress. Per-item HTTP errors mark the item failed and move on; a connectivity
    // failure waits for the network to come back (keeping the foreground service, if any) and
    // retries the same item, or ends the run with NETWORK when it does not come back.
    private suspend fun <T : QueueItem> processQueue(
        db: SQLiteDatabase,
        isDownload: Boolean,
        initial: MutableList<T>,
        reload: (SQLiteDatabase) -> List<T>,
        process: (T) -> ItemResult
    ): QueueRun {
        val run = QueueRun(total = initial.size)
        if (initial.isEmpty()) return run
        val queue = initial
        val attempted = HashSet<String>()
        val startedEvent = if (isDownload) "started_download" else "started"
        val progressEvent = if (isDownload) "progress_download" else "progress"
        val failedEvent = if (isDownload) "failed_download" else "failed"

        BackgroundSyncPlugin.sendProgressUpdate(startedEvent, 0, 0, queue.size)

        var index = 0
        var networkWaits = 0
        while (true) {
            if (isStopped) {
                run.outcome = QueueOutcome.STOPPED
                return run
            }
            if (index >= queue.size) {
                // Records enqueued during the run are sent in the same run.
                val more = try {
                    reload(db).filter { it.id !in attempted }
                } catch (e: Exception) {
                    logE("Failed to re-read queue: ${e.message}", e)
                    emptyList()
                }
                if (more.isEmpty()) break
                logD("Picked up ${more.size} record(s) enqueued during the run")
                queue.addAll(more)
                run.total = queue.size
                continue
            }

            val record = queue[index]
            val position = index + 1
            val percentage = ((position.toFloat() / queue.size.toFloat()) * 100).toInt()
            showProgress(percentage, position, queue.size, isDownload)
            BackgroundSyncPlugin.sendProgressUpdate(progressEvent, percentage, position, queue.size)

            attempted.add(record.id)
            val result = process(record)
            if (result.skipped) {
                // Removed from the queue (removeRecords/clearQueue) after this run loaded it.
                logD("Record ${record.id} is no longer in the queue, skipped")
                index++
                continue
            }
            val error = result.error
            if (error == null) {
                run.processed++
                networkWaits = 0
                index++
                continue
            }

            BackgroundSyncPlugin.sendProgressUpdate(failedEvent, percentage, position - 1, queue.size, error)
            run.lastError = error
            if (!result.connectivityFailure) {
                // The server answered and rejected this item. It is marked failed and stays in
                // the queue for the next run; unrelated items still go out in this one.
                run.processed++
                run.failed++
                index++
                continue
            }

            if (!isStopped && networkWaits < MAX_NETWORK_WAITS_PER_ITEM && !hasUsableNetwork()) {
                networkWaits++
                logI("Connection lost. Waiting up to ${NETWORK_WAIT_MS / 1000}s for the network before retrying ${record.id}")
                showWaitingForNetwork(position - 1, queue.size, isDownload)
                if (waitForNetwork(NETWORK_WAIT_MS)) {
                    logI("Network is back, retrying ${record.id}")
                    continue
                }
            }
            run.outcome = if (isStopped) QueueOutcome.STOPPED else QueueOutcome.NETWORK
            return run
        }
        return run
    }

    private fun loadPendingRecords(db: SQLiteDatabase): MutableList<SyncRecord> {
        val list = mutableListOf<SyncRecord>()
        db.rawQuery(
            "SELECT Id, Endpoint, FilePath, UploadStrategy FROM sync_queue WHERE LOWER(Status) = 'pending' OR LOWER(Status) = 'failed' ORDER BY Sequence ASC",
            null
        ).use { cursor ->
            while (cursor.moveToNext()) {
                list.add(
                    SyncRecord(
                        id = cursor.getString(0),
                        payload = "",
                        endpoint = cursor.getString(1) ?: "",
                        filePath = cursor.getString(2) ?: "",
                        uploadStrategy = cursor.getString(3) ?: "REST_PAYLOAD"
                    )
                )
            }
        }
        return list
    }

    private fun loadPendingDownloads(db: SQLiteDatabase): MutableList<DownloadRecord> {
        val list = mutableListOf<DownloadRecord>()
        db.rawQuery(
            "SELECT Id, Endpoint, Payload, FilePath, DownloadStrategy FROM download_queue WHERE LOWER(Status) = 'pending' OR LOWER(Status) = 'failed' ORDER BY Sequence ASC",
            null
        ).use { cursor ->
            while (cursor.moveToNext()) {
                list.add(
                    DownloadRecord(
                        id = cursor.getString(0),
                        endpoint = cursor.getString(1) ?: "",
                        payload = cursor.getString(2) ?: "",
                        filePath = cursor.getString(3) ?: "",
                        downloadStrategy = cursor.getString(4) ?: "REST_PAYLOAD"
                    )
                )
            }
        }
        return list
    }

    private fun processUpload(db: SQLiteDatabase, record: SyncRecord, serverUrl: String, headersStr: String, autoDeleteCompleted: Boolean): ItemResult {
        // 1. Fetch the payload dynamically
        var recordPayload: String? = null
        try {
            val payloadCursor = db.rawQuery(
                "SELECT Payload FROM sync_queue WHERE Id = ?",
                arrayOf(record.id)
            )
            if (payloadCursor is SQLiteCursor) {
                try {
                    val window = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                        CursorWindow("SingleRowWindow", 16 * 1024 * 1024L)
                    } else {
                        CursorWindow("SingleRowWindow")
                    }
                    payloadCursor.setWindow(window)
                } catch (e: Exception) {
                    logE("Failed to set custom CursorWindow: ${e.message}")
                }
            }
            if (payloadCursor.moveToFirst()) {
                recordPayload = payloadCursor.getString(0) ?: ""
            }
            payloadCursor.close()
        } catch (e: Exception) {
            logE("Failed to fetch payload for record ${record.id}: ${e.message}")
            recordPayload = ""
        }
        if (recordPayload == null) {
            return ItemResult(error = null, skipped = true)
        }

        // Execute native HTTP upload
        val uploadError = if (record.uploadStrategy.equals("PRESIGNED_URL", ignoreCase = true)) {
            performPresignedUrlUpload(serverUrl, record.endpoint, recordPayload, record.filePath, headersStr)
        } else {
            performUpload(serverUrl, record.endpoint, recordPayload, record.filePath, headersStr)
        }

        // Save status in local SQLite database
        try {
            if (uploadError == null) {
                if (autoDeleteCompleted) {
                    db.delete("sync_queue", "Id = ?", arrayOf(record.id))
                } else {
                    val values = ContentValues().apply {
                        put("Status", "completed")
                        putNull("Error")
                    }
                    db.update("sync_queue", values, "Id = ?", arrayOf(record.id))
                }
            } else {
                val values = ContentValues().apply {
                    put("Status", "failed")
                    put("Error", uploadError)
                }
                db.update("sync_queue", values, "Id = ?", arrayOf(record.id))
            }
        } catch (e: Exception) {
            logE("Failed to update record status in database: ${e.message}", e)
        }

        // Only a genuine connectivity failure (the request never reached the server, or the
        // connection dropped mid-request) is transient. An HTTP error response means the server
        // was reached and rejected this specific record.
        val isConnectivityFailure = uploadError != null && (
                uploadError.startsWith("Upload Exception:") ||
                uploadError.startsWith("Handshake exception:") ||
                uploadError.startsWith("Cloud upload Exception:"))
        return ItemResult(uploadError, connectivityFailure = isConnectivityFailure)
    }

    private fun processDownload(db: SQLiteDatabase, record: DownloadRecord, serverUrl: String, headersStr: String): ItemResult {
        val stillQueued = try {
            db.rawQuery("SELECT 1 FROM download_queue WHERE Id = ?", arrayOf(record.id)).use { it.moveToFirst() }
        } catch (e: Exception) {
            true
        }
        if (!stillQueued) {
            return ItemResult(error = null, skipped = true)
        }

        var downloadError: String?
        var responseData: String? = null

        if (record.downloadStrategy == "BINARY_FILE") {
            downloadError = performFileDownload(serverUrl, record.endpoint, record.filePath, headersStr)
        } else {
            val resultPair = performDownload(serverUrl, record.endpoint, record.payload, headersStr)
            downloadError = resultPair.first
            responseData = resultPair.second
        }

        try {
            if (downloadError == null) {
                val values = ContentValues().apply {
                    put("Status", "completed")
                    if (responseData != null) put("ResponseData", responseData)
                    putNull("Error")
                }
                db.update("download_queue", values, "Id = ?", arrayOf(record.id))
            } else {
                val values = ContentValues().apply {
                    put("Status", "failed")
                    put("Error", downloadError)
                }
                db.update("download_queue", values, "Id = ?", arrayOf(record.id))
            }
        } catch (e: Exception) {
            logE("Failed to update download record status in database: ${e.message}", e)
        }

        val isConnectivityFailure = downloadError != null && (
                downloadError.startsWith("Download Exception:") ||
                downloadError.startsWith("File Download Exception:"))
        return ItemResult(downloadError, connectivityFailure = isConnectivityFailure)
    }

    // ----------------------------------------------------------------- notifications ---
    //
    // The progress notification is posted with NotificationManager.notify on a fixed id. When
    // the worker runs as a foreground service that id is the service's notification, and
    // notify() updates it in place. On Android 12+ a run that starts in the background (a
    // retry, a lost constraint coming back) cannot start a foreground service; setForeground
    // then throws, and every later call would fail too, so progress must not depend on it.

    private suspend fun tryPromoteToForeground(notification: Notification): Boolean {
        lastForegroundAttempt = SystemClock.elapsedRealtime()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && !isAppInForeground()) {
            // Android 12+ refuses a foreground service started from the background, and a failed
            // setForeground still leaves WorkManager (2.9) treating the work as foreground: it
            // then ignores system stops (lost constraint, time limit), so the worker is not
            // stopped and rescheduled but left running until the process is frozen. Only ask
            // when the app is visible.
            if (!backgroundStartLogged) {
                logI("App is in the background: running as a regular background worker (Android 12+ does not allow starting a foreground service now)")
                backgroundStartLogged = true
            }
            foregroundActive = false
            return false
        }
        return try {
            setForeground(createForegroundInfo(notification))
            if (!foregroundActive) logI("Running as a foreground service")
            foregroundActive = true
            true
        } catch (e: Throwable) {
            // CancellationException included: a stopped worker is handled by the isStopped checks.
            foregroundActive = false
            logW("Failed to run as Foreground Service: ${e.message}. Posting progress as a regular notification.")
            false
        }
    }

    private suspend fun showProgress(progress: Int, current: Int, total: Int, isDownload: Boolean) {
        if (!enableNotifications) return
        val now = SystemClock.elapsedRealtime()
        // The system drops notification updates posted faster than a few per second, which
        // can leave a stale progress on screen. One update per second is plenty.
        if (now - lastProgressPost < PROGRESS_MIN_INTERVAL_MS && current != total) return
        lastProgressPost = now
        val notification = createNotificationProgress(progress, current, total, isDownload)
        // Not a foreground service yet: try again only when the app is visible (the one state
        // where Android 12+ allows it), and not more than every few seconds.
        if (!foregroundActive && isAppInForeground() && now - lastForegroundAttempt >= FOREGROUND_RETRY_MS) {
            if (tryPromoteToForeground(notification)) return
        }
        postProgressNotification(notification)
    }

    private fun showWaitingForNetwork(done: Int, total: Int, isDownload: Boolean) {
        if (!enableNotifications) return
        val titleKey = if (isDownload) "downloadProgressTitle" else "progressTitle"
        val title = customTexts.optString(titleKey, if (isDownload) "Background Download Active" else "Background Sync Active")
        val body = customTexts.optString("waitingForNetworkBody", "Waiting for a network connection ({current} of {total} done)")
            .replace("{current}", done.toString())
            .replace("{total}", total.toString())
        val notification = NotificationCompat.Builder(applicationContext, progressChannelId)
            .setContentTitle(title)
            .setContentText(body)
            .setSmallIcon(applicationContext.applicationInfo.icon)
            .setProgress(0, 0, true)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
        postProgressNotification(notification)
        lastProgressPost = SystemClock.elapsedRealtime()
    }

    private fun postProgressNotification(notification: Notification) {
        try {
            notificationManager.notify(notificationId, notification)
        } catch (e: Exception) {
            logW("Failed to post progress notification: ${e.message}")
        }
    }

    private fun cancelProgressNotification() {
        try {
            notificationManager.cancel(notificationId)
        } catch (e: Exception) {
            logW("Failed to cancel progress notification: ${e.message}")
        }
    }

    private fun isAppInForeground(): Boolean {
        val info = ActivityManager.RunningAppProcessInfo()
        ActivityManager.getMyMemoryState(info)
        return info.importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
    }

    // ----------------------------------------------------------------------- network ---

    private fun hasUsableNetwork(): Boolean {
        val cm = applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return true
        val network = cm.activeNetwork ?: return false
        val caps = cm.getNetworkCapabilities(network) ?: return false
        if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) return false
        if (syncOnlyOnWifi && !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)) return false
        return true
    }

    private suspend fun waitForNetwork(maxMs: Long): Boolean {
        val deadline = SystemClock.elapsedRealtime() + maxMs
        while (SystemClock.elapsedRealtime() < deadline) {
            if (isStopped) return false
            if (hasUsableNetwork()) return true
            try {
                delay(NETWORK_POLL_MS)
            } catch (e: CancellationException) {
                return false
            }
        }
        return false
    }

    private fun stopReasonCompat(): Int {
        return try {
            stopReason
        } catch (e: Throwable) {
            WorkInfo.STOP_REASON_UNKNOWN
        }
    }

    private fun performUpload(serverUrl: String, endpoint: String, payload: String, filePath: String?, headersStr: String): String? {
        var conn: HttpURLConnection? = null
        val fullUrl = serverUrl.trimEnd('/') + "/" + endpoint.trimStart('/')
        try {
            val url = URL(fullUrl)
            conn = url.openConnection() as HttpURLConnection
            conn.connectTimeout = 300000 // 5 minutes
            conn.readTimeout = 300000    // 5 minutes
            conn.doInput = true
            conn.doOutput = true
            conn.useCaches = false
            conn.requestMethod = "POST"
            conn.setRequestProperty("Connection", "Keep-Alive")
            conn.setRequestProperty("Content-Type", "application/json; charset=UTF-8")

            try {
                val headersJson = JSONObject(headersStr)
                val keys = headersJson.keys()
                while (keys.hasNext()) {
                    val key = keys.next()
                    val value = headersJson.getString(key)
                    conn.setRequestProperty(key, value)
                }
            } catch (e: Exception) {
                logE("Header parsing error: ${e.message}")
            }

            val requestBody = JSONObject()
            try {
                requestBody.put("payload", JSONObject(payload))
            } catch (e: Exception) {
                try {
                    requestBody.put("payload", org.json.JSONArray(payload))
                } catch (e2: Exception) {
                    requestBody.put("payload", payload)
                }
            }

            // The body is streamed: { "payload": ..., "file": { "filename", "contentType",
            // "base64Data" } }. Building it as one JSON string held the file, its base64 copy
            // and the serialized body in memory at once (about 4x the file size), which ran
            // out of memory on large files.
            var file: File? = null
            if (!filePath.isNullOrEmpty()) {
                file = resolveLocalFile(filePath)
                if (!file.exists() || !file.isFile) {
                    // Sending the record without its file and marking it completed would lose the file.
                    return "Local file not found at path: $filePath"
                }
            }
            val payloadJson = requestBody.toString()
            val head: ByteArray
            val tail: ByteArray
            val base64Length: Long
            if (file != null) {
                val fileHead = ",\"file\":{\"filename\":" + JSONObject.quote(file.name) +
                        ",\"contentType\":" + JSONObject.quote(java.net.URLConnection.guessContentTypeFromName(file.name) ?: "application/octet-stream") +
                        ",\"base64Data\":\""
                head = (payloadJson.dropLast(1) + fileHead).toByteArray(Charsets.UTF_8)
                tail = "\"}}".toByteArray(Charsets.UTF_8)
                base64Length = 4L * ((file.length() + 2) / 3)
            } else {
                head = payloadJson.toByteArray(Charsets.UTF_8)
                tail = ByteArray(0)
                base64Length = 0L
            }
            conn.setFixedLengthStreamingMode(head.size + base64Length + tail.size)

            conn.outputStream.buffered(64 * 1024).use { out ->
                out.write(head)
                if (file != null) {
                    val b64 = android.util.Base64OutputStream(out, android.util.Base64.NO_WRAP or android.util.Base64.NO_CLOSE)
                    FileInputStream(file).use { input -> input.copyTo(b64, 64 * 1024) }
                    b64.close()
                }
                out.write(tail)
                out.flush()
            }

            val responseCode = conn.responseCode
            if (responseCode in 200..299) {
                return null
            } else {
                val errorStream = conn.errorStream ?: conn.inputStream
                val errorBody = errorStream?.bufferedReader()?.use { it.readText() } ?: "No details"
                val err = "HTTP $responseCode: $errorBody"
                logE("Network upload failed. URL: $fullUrl. Error: $err")
                return err
            }
        } catch (e: Exception) {
            val err = "Upload Exception: ${e.message ?: e.javaClass.simpleName}"
            logE("Upload Exception for URL: $fullUrl. Error: $err", e)
            return err
        } finally {
            conn?.disconnect()
        }
    }

    private fun performPresignedUrlUpload(serverUrl: String, endpoint: String, payload: String, filePath: String?, headersStr: String): String? {
        if (filePath.isNullOrEmpty()) {
            return "File path is required for Presigned URL upload strategy."
        }
        val file = resolveLocalFile(filePath)
        if (!file.exists() || !file.isFile) {
            return "Local file not found at path: $filePath"
        }

        var connHandshake: HttpURLConnection? = null
        val handshakeUrlStr = serverUrl.trimEnd('/') + "/" + endpoint.trimStart('/')
        var presignedUrl = ""
        var httpMethod = "PUT"
        var customHeaders = JSONObject()

        try {
            val url = URL(handshakeUrlStr)
            connHandshake = url.openConnection() as HttpURLConnection
            connHandshake.connectTimeout = 300000 // 5 minutes
            connHandshake.readTimeout = 300000    // 5 minutes
            connHandshake.doInput = true
            connHandshake.doOutput = true
            connHandshake.useCaches = false
            connHandshake.requestMethod = "POST"
            connHandshake.setRequestProperty("Connection", "Keep-Alive")
            connHandshake.setRequestProperty("Content-Type", "application/json; charset=UTF-8")

            try {
                val headersJson = JSONObject(headersStr)
                val keys = headersJson.keys()
                while (keys.hasNext()) {
                    val key = keys.next()
                    val value = headersJson.getString(key)
                    connHandshake.setRequestProperty(key, value)
                }
            } catch (e: Exception) {
                logE("Handshake header parsing error: ${e.message}")
            }

            val requestBody = JSONObject()
            try {
                requestBody.put("payload", JSONObject(payload))
            } catch (e: Exception) {
                try {
                    requestBody.put("payload", org.json.JSONArray(payload))
                } catch (e2: Exception) {
                    requestBody.put("payload", payload)
                }
            }

            val jsonBytes = requestBody.toString().toByteArray(Charsets.UTF_8)
            connHandshake.setRequestProperty("Content-Length", jsonBytes.size.toString())

            val dos = DataOutputStream(connHandshake.outputStream)
            dos.write(jsonBytes)
            dos.flush()
            dos.close()

            val responseCode = connHandshake.responseCode
            if (responseCode in 200..299) {
                val responseBody = connHandshake.inputStream.bufferedReader().use { it.readText() }
                val responseJson = JSONObject(responseBody)
                presignedUrl = responseJson.getString("uploadUrl")
                httpMethod = responseJson.optString("method", "PUT")
                customHeaders = responseJson.optJSONObject("headers") ?: JSONObject()
            } else {
                val errorStream = connHandshake.errorStream ?: connHandshake.inputStream
                val errorBody = errorStream?.bufferedReader()?.use { it.readText() } ?: "No details"
                return "Handshake failed (HTTP $responseCode): $errorBody"
            }
        } catch (e: Exception) {
            return "Handshake exception: ${e.message ?: e.javaClass.simpleName}"
        } finally {
            connHandshake?.disconnect()
        }

        if (presignedUrl.isEmpty()) {
            return "Server response did not contain a valid 'uploadUrl'."
        }

        var connUpload: HttpURLConnection? = null
        try {
            logI("Starting direct cloud streaming upload to: $presignedUrl")
            val url = URL(presignedUrl)
            connUpload = url.openConnection() as HttpURLConnection
            connUpload.connectTimeout = 300000 // 5 minutes
            connUpload.readTimeout = 300000    // 5 minutes
            connUpload.doOutput = true
            connUpload.requestMethod = httpMethod.uppercase(Locale.ROOT)
            connUpload.useCaches = false
            connUpload.setChunkedStreamingMode(4096)

            val headerKeys = customHeaders.keys()
            while (headerKeys.hasNext()) {
                val key = headerKeys.next()
                val value = customHeaders.getString(key)
                connUpload.setRequestProperty(key, value)
            }

            if (connUpload.getRequestProperty("Content-Type") == null) {
                connUpload.setRequestProperty("Content-Type", java.net.URLConnection.guessContentTypeFromName(file.name) ?: "application/octet-stream")
            }

            val fis = FileInputStream(file)
            val os = connUpload.outputStream
            val buffer = ByteArray(4096)
            var bytesRead: Int
            while (fis.read(buffer).also { bytesRead = it } != -1) {
                os.write(buffer, 0, bytesRead)
            }
            os.flush()
            os.close()
            fis.close()

            val responseCode = connUpload.responseCode
            if (responseCode in 200..299) {
                logI("Direct cloud upload completed successfully. HTTP $responseCode")
                return null
            } else {
                val errorStream = connUpload.errorStream ?: connUpload.inputStream
                val errorBody = errorStream?.bufferedReader()?.use { it.readText() } ?: "No details"
                val err = "Cloud upload failed (HTTP $responseCode): $errorBody"
                logE(err)
                return err
            }
        } catch (e: Exception) {
            val err = "Cloud upload Exception: ${e.message ?: e.javaClass.simpleName}"
            logE(err, e)
            return err
        } finally {
            connUpload?.disconnect()
        }
    }

    // Accepts a plain path or a file:// URL (percent-encoded characters included).
    private fun resolveLocalFile(path: String): File {
        if (path.startsWith("file:")) {
            val decoded = try {
                android.net.Uri.parse(path).path
            } catch (e: Exception) {
                null
            }
            return File(decoded ?: path.removePrefix("file://"))
        }
        return File(path)
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val progressName = "Sync Progress"
            val progressDesc = "Monitors background synchronization progress (Silent)"
            val progressChannel = NotificationChannel(progressChannelId, progressName, NotificationManager.IMPORTANCE_LOW).apply {
                description = progressDesc
                enableLights(false)
                enableVibration(false)
                setSound(null, null)
            }
            notificationManager.createNotificationChannel(progressChannel)

            val alertsName = "Sync Alerts"
            val alertsDesc = "Alerts for successful or failed synchronization cycles"
            val alertsChannel = NotificationChannel(alertsChannelId, alertsName, NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = alertsDesc
            }
            notificationManager.createNotificationChannel(alertsChannel)
        }
    }

    private fun createNotificationProgress(progress: Int, current: Int, total: Int, isDownload: Boolean = false): Notification {
        val defaultTitle = if (isDownload) "Background Download Active" else "Background Sync Active"
        val defaultProgressBody = if (isDownload) {
            "Downloading: {current} of {total} files ({percentage}%)"
        } else {
            "Synchronizing: {current} of {total} records ({percentage}%)"
        }
        val defaultPreparingBody = if (isDownload) "Preparing downloads..." else "Preparing database synchronization..."

        val titleKey = if (isDownload) "downloadProgressTitle" else "progressTitle"
        val bodyKey = if (isDownload) "downloadProgressBody" else "progressBody"
        val preparingKey = if (isDownload) "downloadPreparingBody" else "preparingBody"

        val title = customTexts.optString(titleKey, defaultTitle)
        val contentText = if (total > 0) {
            val progressBody = customTexts.optString(bodyKey, defaultProgressBody)
            progressBody
                .replace("{current}", current.toString())
                .replace("{total}", total.toString())
                .replace("{percentage}", progress.toString())
        } else {
            customTexts.optString(preparingKey, defaultPreparingBody)
        }

        return NotificationCompat.Builder(applicationContext, progressChannelId)
            .setContentTitle(title)
            .setContentText(contentText)
            .setSmallIcon(applicationContext.applicationInfo.icon)
            .setProgress(100, progress, false)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }

    private fun createForegroundInfo(notification: Notification): ForegroundInfo {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ForegroundInfo(notificationId, notification, android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            ForegroundInfo(notificationId, notification)
        }
    }

    private fun updateNotificationSuccess() {
        val defaultTitle = "Synchronization Complete"
        val defaultBody = "All offline records successfully uploaded."

        val title = customTexts.optString("successTitle", defaultTitle)
        val body = customTexts.optString("successBody", defaultBody)

        val notification = NotificationCompat.Builder(applicationContext, alertsChannelId)
            .setContentTitle(title)
            .setContentText(body)
            .setSmallIcon(applicationContext.applicationInfo.icon)
            .build()
        postResultNotification(notification)
    }

    private fun updateNotificationFailure(error: String, isDownload: Boolean = false) {
        val defaultTitle = if (isDownload) "Download Suspended" else "Synchronization Suspended"
        val defaultBody = if (isDownload) "Download failed: {error}. Will retry automatically." else "Sync failed: {error}. Will retry automatically."

        val titleKey = if (isDownload) "downloadFailureTitle" else "failureTitle"
        val bodyKey = if (isDownload) "downloadFailureBody" else "failureBody"

        val title = customTexts.optString(titleKey, defaultTitle)
        val body = customTexts.optString(bodyKey, defaultBody)
            .replace("{error}", error)

        val notification = NotificationCompat.Builder(applicationContext, alertsChannelId)
            .setContentTitle(title)
            .setContentText(body)
            .setSmallIcon(applicationContext.applicationInfo.icon)
            .build()
        postResultNotification(notification)
    }

    // The run reached the end of the queues, but the server rejected some items. They stay in
    // the queue (status "failed") and are sent again by the next run.
    private fun updateNotificationPartial(failed: Int, total: Int, lastError: String) {
        val title = customTexts.optString("partialTitle", "Synchronization Finished With Errors")
        val body = customTexts.optString("partialBody", "{failed} of {total} items were rejected by the server and stay queued for the next sync.")
            .replace("{failed}", failed.toString())
            .replace("{total}", total.toString())
            .replace("{error}", lastError)

        val notification = NotificationCompat.Builder(applicationContext, alertsChannelId)
            .setContentTitle(title)
            .setContentText(body)
            .setSmallIcon(applicationContext.applicationInfo.icon)
            .build()
        postResultNotification(notification)
    }

    // The system stopped the run (time limit, lost constraint, quota). WorkManager runs it again.
    private fun updateNotificationPaused(done: Int, total: Int, isDownload: Boolean) {
        val title = customTexts.optString("pausedTitle", "Synchronization Paused")
        val body = customTexts.optString("pausedBody", "{current} of {total} done. The sync resumes automatically when Android allows it.")
            .replace("{current}", done.toString())
            .replace("{total}", total.toString())

        val notification = NotificationCompat.Builder(applicationContext, progressChannelId)
            .setContentTitle(title)
            .setContentText(body)
            .setSmallIcon(applicationContext.applicationInfo.icon)
            .setOnlyAlertOnce(true)
            .build()
        postResultNotification(notification)
    }

    // Final notifications use their own id: WorkManager removes the foreground service's
    // notification (the progress id) when the run ends, which would take a final notification
    // posted on that id with it.
    private fun postResultNotification(notification: Notification) {
        try {
            notificationManager.notify(resultNotificationId, notification)
        } catch (e: Exception) {
            logW("Failed to post notification: ${e.message}")
        }
    }

    private fun logD(message: String) {
        if (showDebugLogs) android.util.Log.d("BackgroundSyncPlugin", message)
    }

    private fun logI(message: String) {
        if (showDebugLogs) android.util.Log.i("BackgroundSyncPlugin", message)
    }

    private fun logW(message: String) {
        if (showDebugLogs) android.util.Log.w("BackgroundSyncPlugin", message)
    }

    private fun logE(message: String, throwable: Throwable? = null) {
        if (showDebugLogs) {
            if (throwable != null) {
                android.util.Log.e("BackgroundSyncPlugin", message, throwable)
            } else {
                android.util.Log.e("BackgroundSyncPlugin", message)
            }
        }
    }

    private fun performDownload(serverUrl: String, endpoint: String, payload: String, headersStr: String): Pair<String?, String?> {
        var conn: HttpURLConnection? = null
        val fullUrl = if (endpoint.startsWith("http://") || endpoint.startsWith("https://")) {
            endpoint
        } else {
            serverUrl.trimEnd('/') + "/" + endpoint.trimStart('/')
        }
        try {
            val url = URL(fullUrl)
            conn = url.openConnection() as HttpURLConnection
            conn.connectTimeout = 300000 // 5 minutes
            conn.readTimeout = 300000    // 5 minutes
            conn.doInput = true
            conn.doOutput = payload.isNotEmpty()
            conn.useCaches = false
            conn.requestMethod = if (payload.isNotEmpty()) "POST" else "GET"
            conn.setRequestProperty("Connection", "Keep-Alive")
            conn.setRequestProperty("Content-Type", "application/json; charset=UTF-8")

            try {
                val headersJson = JSONObject(headersStr)
                val keys = headersJson.keys()
                while (keys.hasNext()) {
                    val key = keys.next()
                    val value = headersJson.getString(key)
                    conn.setRequestProperty(key, value)
                }
            } catch (e: Exception) {
                logE("Header parsing error: ${e.message}")
            }

            if (payload.isNotEmpty()) {
                val requestBody = JSONObject()
                try {
                    requestBody.put("payload", JSONObject(payload))
                } catch (e: Exception) {
                    try {
                        requestBody.put("payload", org.json.JSONArray(payload))
                    } catch (e2: Exception) {
                        requestBody.put("payload", payload)
                    }
                }
                val jsonBytes = requestBody.toString().toByteArray(Charsets.UTF_8)
                conn.setRequestProperty("Content-Length", jsonBytes.size.toString())
                val dos = DataOutputStream(conn.outputStream)
                dos.write(jsonBytes)
                dos.flush()
                dos.close()
            }

            val responseCode = conn.responseCode
            if (responseCode in 200..299) {
                val responseBody = conn.inputStream.bufferedReader().use { it.readText() }
                return Pair(null, responseBody)
            } else {
                val errorStream = conn.errorStream ?: conn.inputStream
                val errorBody = errorStream?.bufferedReader()?.use { it.readText() } ?: "No details"
                val err = "HTTP $responseCode: $errorBody"
                logE("Download request failed. URL: $fullUrl. Error: $err")
                return Pair(err, null)
            }
        } catch (e: Exception) {
            val err = "Download Exception: ${e.message ?: e.javaClass.simpleName}"
            logE("Download Exception for URL: $fullUrl. Error: $err", e)
            return Pair(err, null)
        } finally {
            conn?.disconnect()
        }
    }

    private fun performFileDownload(serverUrl: String, downloadUrl: String, filePath: String, headersStr: String): String? {
        var conn: HttpURLConnection? = null
        val fullUrl = if (downloadUrl.startsWith("http://") || downloadUrl.startsWith("https://")) {
            downloadUrl
        } else {
            serverUrl.trimEnd('/') + "/" + downloadUrl.trimStart('/')
        }
        try {
            val url = URL(fullUrl)
            conn = url.openConnection() as HttpURLConnection
            conn.connectTimeout = 300000 // 5 minutes
            conn.readTimeout = 300000    // 5 minutes
            conn.doInput = true
            conn.useCaches = false
            conn.requestMethod = "GET"
            conn.setRequestProperty("Connection", "Keep-Alive")

            try {
                val headersJson = JSONObject(headersStr)
                val keys = headersJson.keys()
                while (keys.hasNext()) {
                    val key = keys.next()
                    val value = headersJson.getString(key)
                    conn.setRequestProperty(key, value)
                }
            } catch (e: Exception) {
                logE("Header parsing error: ${e.message}")
            }

            val responseCode = conn.responseCode
            if (responseCode in 200..299) {
                val file = resolveLocalFile(filePath)
                val parentDir = file.parentFile
                if (parentDir != null && !parentDir.exists()) {
                    parentDir.mkdirs()
                }
                
                conn.inputStream.use { input ->
                    file.outputStream().use { output ->
                        val buffer = ByteArray(4096)
                        var bytesRead: Int
                        while (input.read(buffer).also { bytesRead = it } != -1) {
                            output.write(buffer, 0, bytesRead)
                        }
                    }
                }
                return null
            } else {
                val errorStream = conn.errorStream ?: conn.inputStream
                val errorBody = errorStream?.bufferedReader()?.use { it.readText() } ?: "No details"
                val err = "HTTP $responseCode: $errorBody"
                logE("File download failed. URL: $downloadUrl. Error: $err")
                return err
            }
        } catch (e: Exception) {
            val err = "File Download Exception: ${e.message ?: e.javaClass.simpleName}"
            logE("File Download Exception for URL: $downloadUrl. Error: $err", e)
            return err
        } finally {
            conn?.disconnect()
        }
    }
}

interface QueueItem {
    val id: String
}

enum class QueueOutcome { DONE, STOPPED, NETWORK }

class QueueRun(
    var total: Int,
    var processed: Int = 0,
    var failed: Int = 0,
    var lastError: String? = null,
    var outcome: QueueOutcome = QueueOutcome.DONE
)

class ItemResult(
    val error: String?,
    val connectivityFailure: Boolean = false,
    val skipped: Boolean = false
)

data class DownloadRecord(
    override val id: String,
    val endpoint: String,
    val payload: String,
    val filePath: String,
    val downloadStrategy: String
) : QueueItem

data class SyncRecord(
    override val id: String,
    val payload: String,
    val endpoint: String,
    val filePath: String,
    val uploadStrategy: String
) : QueueItem
