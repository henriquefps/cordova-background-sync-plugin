package com.hfps.backgroundsync

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.database.CursorWindow
import android.database.sqlite.SQLiteCursor
import android.database.sqlite.SQLiteDatabase
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters
import kotlinx.coroutines.Dispatchers
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
    private var customTexts = JSONObject()
    private var showDebugLogs = false

    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val sharedPref = applicationContext.getSharedPreferences(
            BackgroundSyncPlugin.PREFS_NAME,
            Context.MODE_PRIVATE
        )
        showDebugLogs = sharedPref.getBoolean(BackgroundSyncPlugin.KEY_SHOW_DEBUG_LOGS, false)
        val serverUrl = sharedPref.getString(BackgroundSyncPlugin.KEY_SERVER_URL, "") ?: ""
        val enableNotifications = sharedPref.getBoolean(BackgroundSyncPlugin.KEY_ENABLE_NOTIFICATIONS, true)
        val autoDeleteCompleted = sharedPref.getBoolean(BackgroundSyncPlugin.KEY_AUTO_DELETE_COMPLETED, false)
        val headersStr = sharedPref.getString(BackgroundSyncPlugin.KEY_HEADERS, "{}") ?: "{}"
        val notificationTextsStr = sharedPref.getString(BackgroundSyncPlugin.KEY_NOTIFICATION_TEXTS, "{}") ?: "{}"
        val encryptDatabase = sharedPref.getBoolean(BackgroundSyncPlugin.KEY_ENCRYPT_DATABASE, false)

        try {
            customTexts = JSONObject(notificationTextsStr)
        } catch (e: Exception) {
            e.printStackTrace()
        }

        if (serverUrl.isEmpty()) {
            return@withContext Result.failure()
        }

        if (enableNotifications) {
            createNotificationChannel()
            try {
                setForeground(createForegroundInfo(0, 0, 0))
            } catch (e: Exception) {
                logW("Failed to run as Foreground Service: ${e.message}. Falling back to standard background execution.")
            }
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
            return@withContext Result.failure()
        }

        try {
            val pendingRecords = mutableListOf<SyncRecord>()
            try {
                val cursor = db.rawQuery(
                    "SELECT Id, Endpoint, FilePath, UploadStrategy FROM sync_queue WHERE LOWER(Status) = 'pending' OR LOWER(Status) = 'failed' ORDER BY Sequence ASC",
                    null
                )
                while (cursor.moveToNext()) {
                    pendingRecords.add(
                        SyncRecord(
                            id = cursor.getString(0),
                            payload = "",
                            endpoint = cursor.getString(1),
                            filePath = cursor.getString(2) ?: "",
                            uploadStrategy = cursor.getString(3) ?: "REST_PAYLOAD"
                        )
                    )
                }
                cursor.close()
            } catch (e: Exception) {
                logE("Failed to load records from sync queue: ${e.message}", e)
                BackgroundSyncPlugin.sendProgressUpdate("failed", 0, 0, 0, e.message)
                return@withContext Result.failure()
            }

            val totalCount = pendingRecords.size
            logD("Total queued pending sync records: $totalCount")

            val pendingDownloads = mutableListOf<DownloadRecord>()
            try {
                val cursor = db.rawQuery(
                    "SELECT Id, Endpoint, Payload, FilePath, DownloadStrategy FROM download_queue WHERE LOWER(Status) = 'pending' OR LOWER(Status) = 'failed' ORDER BY Sequence ASC",
                    null
                )
                while (cursor.moveToNext()) {
                    pendingDownloads.add(
                        DownloadRecord(
                            id = cursor.getString(0),
                            endpoint = cursor.getString(1),
                            payload = cursor.getString(2) ?: "",
                            filePath = cursor.getString(3) ?: "",
                            downloadStrategy = cursor.getString(4) ?: "REST_PAYLOAD"
                        )
                    )
                }
                cursor.close()
            } catch (e: Exception) {
                logE("Failed to load records from download queue: ${e.message}", e)
            }

            val totalDownloadCount = pendingDownloads.size
            logD("Total queued pending download records: $totalDownloadCount")

            if (totalCount == 0 && totalDownloadCount == 0) {
                if (enableNotifications) {
                    updateNotificationSuccess()
                }
                return@withContext Result.success()
            }

            var completedCount = 0
            var syncAborted = false
            var isTransientNetworkError = false

            if (totalCount > 0) {
                // Broadcast onStarted event
                BackgroundSyncPlugin.sendProgressUpdate("started", 0, 0, totalCount)

                for (record in pendingRecords) {
                    if (isStopped) {
                        syncAborted = true
                        isTransientNetworkError = false
                        break
                    }

                    completedCount++
                    val percentage = ((completedCount.toFloat() / totalCount.toFloat()) * 100).toInt()

                    if (enableNotifications) {
                        try {
                            setForeground(createForegroundInfo(percentage, completedCount, totalCount))
                        } catch (e: Exception) {
                            logW("Failed to update Foreground Service progress notification: ${e.message}")
                        }
                    }

                    BackgroundSyncPlugin.sendProgressUpdate("progress", percentage, completedCount, totalCount)

                    // 1. Fetch the payload dynamically
                    var recordPayload = ""
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

                    if (uploadError != null) {
                        if (enableNotifications) {
                            updateNotificationFailure(uploadError)
                        }
                        BackgroundSyncPlugin.sendProgressUpdate("failed", percentage, completedCount - 1, totalCount, uploadError)

                        // Only a genuine connectivity failure (the request never reached the server)
                        // should abort the whole run. An HTTP error response means the server was
                        // reached and rejected this specific record — it's already marked "failed"
                        // above; let the loop continue so unrelated queued items still get attempted.
                        val isConnectivityFailure = uploadError.startsWith("Upload Exception:") ||
                                uploadError.startsWith("Handshake exception:") ||
                                uploadError.startsWith("Cloud upload Exception:")
                        if (isConnectivityFailure) {
                            isTransientNetworkError = true
                            syncAborted = true
                        }
                    }

                    if (syncAborted) {
                        break
                    }
                }

                if (syncAborted) {
                    return@withContext if (isTransientNetworkError) {
                        logI("Sync worker aborted due to transient network error. Rescheduling retry...")
                        Result.retry()
                    } else {
                        Result.failure()
                    }
                }
            }

            // ----------------- DOWNLOAD PROCESS -----------------
            logD("Total queued pending download records: $totalDownloadCount")

            var completedDownloadCount = 0
            var downloadAborted = false
            var isDownloadTransientNetworkError = false

            if (totalDownloadCount > 0) {
                BackgroundSyncPlugin.sendProgressUpdate("started_download", 0, 0, totalDownloadCount)

                for (record in pendingDownloads) {
                    if (isStopped) {
                        downloadAborted = true
                        isDownloadTransientNetworkError = false
                        break
                    }

                    completedDownloadCount++
                    val percentage = ((completedDownloadCount.toFloat() / totalDownloadCount.toFloat()) * 100).toInt()

                    if (enableNotifications) {
                        try {
                            setForeground(createForegroundInfo(percentage, completedDownloadCount, totalDownloadCount, isDownload = true))
                        } catch (e: Exception) {
                            logW("Failed to update Foreground Service progress notification: ${e.message}")
                        }
                    }

                    BackgroundSyncPlugin.sendProgressUpdate("progress_download", percentage, completedDownloadCount, totalDownloadCount)

                    var downloadError: String? = null
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

                    if (downloadError != null) {
                        if (enableNotifications) {
                            updateNotificationFailure(downloadError, isDownload = true)
                        }
                        BackgroundSyncPlugin.sendProgressUpdate("failed_download", percentage, completedDownloadCount - 1, totalDownloadCount, downloadError)

                        // Only a genuine connectivity failure (the request never reached the server)
                        // should abort the whole run. An HTTP error response means the server was
                        // reached and rejected this specific record — it's already marked "failed"
                        // above; let the loop continue so unrelated queued items still get attempted.
                        val isConnectivityFailure = downloadError.startsWith("Download Exception:") ||
                                downloadError.startsWith("File Download Exception:")
                        if (isConnectivityFailure) {
                            isDownloadTransientNetworkError = true
                            downloadAborted = true
                        }
                    }

                    if (downloadAborted) {
                        break
                    }
                }

                if (downloadAborted) {
                    return@withContext if (isDownloadTransientNetworkError) {
                        logI("Download worker aborted due to transient network error. Rescheduling retry...")
                        Result.retry()
                    } else {
                        Result.failure()
                    }
                }
            }

            if (enableNotifications) {
                updateNotificationSuccess()
            }

            BackgroundSyncPlugin.sendProgressUpdate("completed", 100, completedCount + completedDownloadCount, totalCount + totalDownloadCount)
            return@withContext Result.success()
        } finally {
            db.close()
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

            if (!filePath.isNullOrEmpty()) {
                val cleanPath = filePath.replace("file://", "")
                val file = File(cleanPath)
                if (file.exists() && file.isFile) {
                    val fileBytes = file.readBytes()
                    val base64Data = android.util.Base64.encodeToString(fileBytes, android.util.Base64.NO_WRAP)
                    
                    val fileJson = JSONObject().apply {
                        put("filename", file.name)
                        put("contentType", java.net.URLConnection.guessContentTypeFromName(file.name) ?: "application/octet-stream")
                        put("base64Data", base64Data)
                    }
                    requestBody.put("file", fileJson)
                }
            }

            val jsonBytes = requestBody.toString().toByteArray(Charsets.UTF_8)
            conn.setRequestProperty("Content-Length", jsonBytes.size.toString())

            val dos = DataOutputStream(conn.outputStream)
            dos.write(jsonBytes)
            dos.flush()
            dos.close()

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
        val cleanPath = filePath.replace("file://", "")
        val file = File(cleanPath)
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
            .build()
    }

    private fun createForegroundInfo(progress: Int, current: Int, total: Int, isDownload: Boolean = false): ForegroundInfo {
        val notification = createNotificationProgress(progress, current, total, isDownload)
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
        notificationManager.notify(notificationId, notification)
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
        notificationManager.notify(notificationId, notification)
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
                val cleanPath = filePath.replace("file://", "")
                val file = File(cleanPath)
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

data class DownloadRecord(
    val id: String,
    val endpoint: String,
    val payload: String,
    val filePath: String,
    val downloadStrategy: String
)

data class SyncRecord(
    val id: String,
    val payload: String,
    val endpoint: String,
    val filePath: String,
    val uploadStrategy: String
)
