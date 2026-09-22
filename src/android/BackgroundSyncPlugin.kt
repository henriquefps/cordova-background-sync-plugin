package com.hfps.backgroundsync

import android.content.Context
import android.content.SharedPreferences
import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.work.*
import org.apache.cordova.CallbackContext
import org.apache.cordova.CordovaPlugin
import org.apache.cordova.PluginResult
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.util.concurrent.TimeUnit
import android.content.ContentValues
import android.database.sqlite.SQLiteDatabase

class BackgroundSyncPlugin : CordovaPlugin() {

    override fun execute(
        action: String,
        args: JSONArray,
        callbackContext: CallbackContext
    ): Boolean {
        return when (action) {
            "initialize" -> {
                try {
                    val options = args.getJSONObject(0)
                    initialize(options, callbackContext)
                } catch (e: JSONException) {
                    callbackContext.error("Invalid initialization arguments: ${e.message}")
                }
                true
            }
            "enqueueSync" -> {
                enqueueSync(callbackContext)
                true
            }
            "registerProgressListener" -> {
                registerProgressListener(callbackContext)
                true
            }
            "requestNotificationsPermission" -> {
                requestNotificationsPermission(callbackContext)
                true
            }
            "executeRawQuery" -> {
                val query = args.getString(0)
                val queryArgs = args.optJSONArray(1)
                executeRawQuery(query, queryArgs, callbackContext)
                true
            }
            "enqueueRecord" -> {
                val record = args.getJSONObject(0)
                enqueueRecord(record, callbackContext)
                true
            }
            "getQueuedRecords" -> {
                getQueuedRecords(callbackContext)
                true
            }
            "getSyncedRecords" -> {
                getSyncedRecords(callbackContext)
                true
            }
            "removeRecords" -> {
                val ids = args.getJSONArray(0)
                removeRecords(ids, callbackContext)
                true
            }
            "clearQueue" -> {
                clearQueue(callbackContext)
                true
            }
            "cancelSync" -> {
                cancelSync(callbackContext)
                true
            }
            "enqueueDownload" -> {
                val record = args.getJSONObject(0)
                enqueueDownload(record, callbackContext)
                true
            }
            "getQueuedDownloads" -> {
                getQueuedDownloads(callbackContext)
                true
            }
            "getCompletedDownloads" -> {
                val options = args.optJSONObject(0) ?: JSONObject()
                getCompletedDownloads(options, callbackContext)
                true
            }
            "removeDownloads" -> {
                val ids = args.getJSONArray(0)
                removeDownloads(ids, callbackContext)
                true
            }
            "clearDownloadQueue" -> {
                clearDownloadQueue(callbackContext)
                true
            }
            "openDatabaseInspector" -> {
                openDatabaseInspector(callbackContext)
                true
            }
            else -> false
        }
    }

    private fun initialize(options: JSONObject, callbackContext: CallbackContext) {
        val serverUrl = options.optString("serverUrl", "")
        val queueTableName = options.optString("queueTableName", "")
        val syncOnlyOnWifi = options.optBoolean("syncOnlyOnWifi", true)
        val syncOnlyWhenCharging = options.optBoolean("syncOnlyWhenCharging", false)
        val enableNotifications = options.optBoolean("enableNotifications", true)
        val autoDeleteCompleted = options.optBoolean("autoDeleteCompleted", false)
        val headers = options.optJSONObject("headers")
        val notificationTexts = options.optJSONObject("notificationTexts")
        val showDebugLogs = options.optBoolean("showDebugLogs", false)
        val encryptDatabase = options.optBoolean("encryptDatabase", false)

        if (serverUrl.isEmpty()) {
            callbackContext.error("serverUrl is a required parameter.")
            return
        }

        val sharedPref = cordova.context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        with(sharedPref.edit()) {
            putString(KEY_SERVER_URL, serverUrl)
            putString(KEY_QUEUE_TABLE_NAME, queueTableName)
            putBoolean(KEY_SYNC_ONLY_ON_WIFI, syncOnlyOnWifi)
            putBoolean(KEY_SYNC_ONLY_WHEN_CHARGING, syncOnlyWhenCharging)
            putBoolean(KEY_ENABLE_NOTIFICATIONS, enableNotifications)
            putBoolean(KEY_AUTO_DELETE_COMPLETED, autoDeleteCompleted)
            putBoolean(KEY_SHOW_DEBUG_LOGS, showDebugLogs)
            putBoolean(KEY_ENCRYPT_DATABASE, encryptDatabase)
            putString(KEY_HEADERS, headers?.toString() ?: "{}")
            putString(KEY_NOTIFICATION_TEXTS, notificationTexts?.toString() ?: "{}")
            apply()
        }

        // Initialize/verify database path and encryption settings eagerly
        try {
            val db = DatabaseHelper.getWritableDatabase(cordova.context, encryptDatabase)
            db.close()
        } catch (e: Exception) {
            android.util.Log.e("BackgroundSyncPlugin", "Database initialization failed: ${e.message}")
        }

        callbackContext.success("Background Sync Engine successfully configured.")
    }

    private fun enqueueSync(callbackContext: CallbackContext) {
        val sharedPref = cordova.context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val serverUrl = sharedPref.getString(KEY_SERVER_URL, "") ?: ""

        if (serverUrl.isEmpty()) {
            callbackContext.error("Background Sync Engine is not initialized. Please call initialize first.")
            return
        }

        val syncOnlyOnWifi = sharedPref.getBoolean(KEY_SYNC_ONLY_ON_WIFI, true)
        val syncOnlyWhenCharging = sharedPref.getBoolean(KEY_SYNC_ONLY_WHEN_CHARGING, false)

        val constraints = Constraints.Builder()
            .setRequiredNetworkType(if (syncOnlyOnWifi) NetworkType.UNMETERED else NetworkType.CONNECTED)
            .setRequiresCharging(syncOnlyWhenCharging)
            .build()

        val syncWorkRequest = OneTimeWorkRequestBuilder<SyncWorker>()
            .setConstraints(constraints)
            .setInitialDelay(1, TimeUnit.SECONDS)
            .setBackoffCriteria(
                BackoffPolicy.EXPONENTIAL,
                WorkRequest.MIN_BACKOFF_MILLIS,
                TimeUnit.MILLISECONDS
            )
            .addTag(WORK_TAG)
            .build()

        val workManager = WorkManager.getInstance(cordova.context)
        workManager.cancelUniqueWork(UNIQUE_WORK_NAME)
        workManager.enqueueUniqueWork(
            UNIQUE_WORK_NAME,
            ExistingWorkPolicy.REPLACE,
            syncWorkRequest
        )

        callbackContext.success("WorkManager sync task enqueued successfully.")
    }

    private fun executeRawQuery(query: String, queryArgs: JSONArray?, callbackContext: CallbackContext) {
        cordova.threadPool.execute {
            val sharedPref = cordova.context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val encryptDatabase = sharedPref.getBoolean(KEY_ENCRYPT_DATABASE, false)
            var db: SQLiteDatabase? = null
            try {
                db = DatabaseHelper.getWritableDatabase(cordova.context, encryptDatabase)
                val selectionArgs = if (queryArgs != null && queryArgs.length() > 0) {
                    Array(queryArgs.length()) { i -> queryArgs.getString(i) }
                } else {
                    null
                }

                val trimmedQuery = query.trim()
                if (trimmedQuery.startsWith("SELECT", true) || trimmedQuery.startsWith("PRAGMA", true)) {
                    val cursor = db.rawQuery(trimmedQuery, selectionArgs)
                    val resultList = JSONArray()
                    while (cursor.moveToNext()) {
                        val row = JSONObject()
                        for (i in 0 until cursor.columnCount) {
                            row.put(cursor.getColumnName(i), cursor.getString(i))
                        }
                        resultList.put(row)
                    }
                    cursor.close()
                    callbackContext.success(resultList)
                } else {
                    if (selectionArgs != null) {
                        db.execSQL(trimmedQuery, selectionArgs)
                    } else {
                        db.execSQL(trimmedQuery)
                    }
                    callbackContext.success("Query executed successfully.")
                }
            } catch (e: Exception) {
                callbackContext.error("Database execution error: ${e.message}")
            } finally {
                db?.close()
            }
        }
    }

    private fun enqueueRecord(record: JSONObject, callbackContext: CallbackContext) {
        cordova.threadPool.execute {
            val sharedPref = cordova.context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val encryptDatabase = sharedPref.getBoolean(KEY_ENCRYPT_DATABASE, false)
            var db: SQLiteDatabase? = null
            try {
                db = DatabaseHelper.getWritableDatabase(cordova.context, encryptDatabase)
                
                var id = record.optString("id", "")
                if (id.isEmpty()) {
                    id = java.util.UUID.randomUUID().toString()
                }
                val endpoint = record.optString("endpoint", "")
                val payload = record.optString("payload", "")
                val filePath = record.optString("filePath", "")
                val uploadStrategy = record.optString("uploadStrategy", "REST_PAYLOAD")

                val values = ContentValues().apply {
                    put("Id", id)
                    put("Endpoint", endpoint)
                    put("Payload", payload)
                    if (filePath.isNotEmpty()) put("FilePath", filePath)
                    put("UploadStrategy", uploadStrategy)
                    put("Status", "pending")
                }

                db.insertWithOnConflict("sync_queue", null, values, SQLiteDatabase.CONFLICT_REPLACE)

                val result = JSONObject().apply {
                    put("id", id)
                    put("status", "pending")
                }
                callbackContext.success(result)
            } catch (e: Exception) {
                callbackContext.error("Failed to enqueue record: ${e.message}")
            } finally {
                db?.close()
            }
        }
    }

    private fun getQueuedRecords(callbackContext: CallbackContext) {
        cordova.threadPool.execute {
            val sharedPref = cordova.context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val encryptDatabase = sharedPref.getBoolean(KEY_ENCRYPT_DATABASE, false)
            var db: SQLiteDatabase? = null
            try {
                db = DatabaseHelper.getWritableDatabase(cordova.context, encryptDatabase)
                val cursor = db.rawQuery(
                    "SELECT Id, Status, Error FROM sync_queue WHERE LOWER(Status) = 'pending' OR LOWER(Status) = 'failed' ORDER BY Sequence ASC",
                    null
                )
                val result = JSONArray()
                while (cursor.moveToNext()) {
                    val row = JSONObject().apply {
                        put("id", cursor.getString(0))
                        put("status", cursor.getString(1))
                        put("error", cursor.getString(2) ?: "")
                    }
                    result.put(row)
                }
                cursor.close()
                callbackContext.success(result)
            } catch (e: Exception) {
                callbackContext.error("Failed to query queued records: ${e.message}")
            } finally {
                db?.close()
            }
        }
    }

    private fun getSyncedRecords(callbackContext: CallbackContext) {
        cordova.threadPool.execute {
            val sharedPref = cordova.context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val encryptDatabase = sharedPref.getBoolean(KEY_ENCRYPT_DATABASE, false)
            var db: SQLiteDatabase? = null
            try {
                db = DatabaseHelper.getWritableDatabase(cordova.context, encryptDatabase)
                val cursor = db.rawQuery(
                    "SELECT Id, Status FROM sync_queue WHERE LOWER(Status) = 'completed' ORDER BY Sequence ASC",
                    null
                )
                val result = JSONArray()
                while (cursor.moveToNext()) {
                    val row = JSONObject().apply {
                        put("id", cursor.getString(0))
                        put("status", cursor.getString(1))
                    }
                    result.put(row)
                }
                cursor.close()
                callbackContext.success(result)
            } catch (e: Exception) {
                callbackContext.error("Failed to query synced records: ${e.message}")
            } finally {
                db?.close()
            }
        }
    }

    private fun removeRecords(ids: JSONArray, callbackContext: CallbackContext) {
        cordova.threadPool.execute {
            val sharedPref = cordova.context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val encryptDatabase = sharedPref.getBoolean(KEY_ENCRYPT_DATABASE, false)
            var db: SQLiteDatabase? = null
            try {
                db = DatabaseHelper.getWritableDatabase(cordova.context, encryptDatabase)
                db.beginTransaction()
                for (i in 0 until ids.length()) {
                    val id = ids.getString(i)
                    db.delete("sync_queue", "Id = ?", arrayOf(id))
                }
                db.setTransactionSuccessful()
                db.endTransaction()
                callbackContext.success("Records removed successfully.")
            } catch (e: Exception) {
                callbackContext.error("Failed to remove records: ${e.message}")
            } finally {
                db?.close()
            }
        }
    }

    private fun clearQueue(callbackContext: CallbackContext) {
        cordova.threadPool.execute {
            val sharedPref = cordova.context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val encryptDatabase = sharedPref.getBoolean(KEY_ENCRYPT_DATABASE, false)
            var db: SQLiteDatabase? = null
            try {
                db = DatabaseHelper.getWritableDatabase(cordova.context, encryptDatabase)
                db.delete("sync_queue", null, null)
                callbackContext.success("Queue cleared successfully.")
            } catch (e: Exception) {
                callbackContext.error("Failed to clear queue: ${e.message}")
            } finally {
                db?.close()
            }
        }
    }

    private fun registerProgressListener(callbackContext: CallbackContext) {
        progressCallbackContext = callbackContext
        val result = PluginResult(PluginResult.Status.NO_RESULT)
        result.keepCallback = true
        callbackContext.sendPluginResult(result)
    }

    private var permissionCallbackContext: CallbackContext? = null

    private fun requestNotificationsPermission(callbackContext: CallbackContext) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (cordova.hasPermission(Manifest.permission.POST_NOTIFICATIONS)) {
                callbackContext.success("Permission already granted.")
            } else {
                permissionCallbackContext = callbackContext
                cordova.requestPermission(this, NOTIFICATION_REQUEST_CODE, Manifest.permission.POST_NOTIFICATIONS)
            }
        } else {
            callbackContext.success("Permission granted by default on this Android version.")
        }
    }

    override fun onRequestPermissionResult(
        requestCode: Int,
        permissions: Array<out String>?,
        grantResults: IntArray?
    ) {
        if (requestCode == NOTIFICATION_REQUEST_CODE) {
            val context = permissionCallbackContext ?: return
            if (grantResults != null && grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                context.success("Permission GRANTED")
            } else {
                context.error("Permission DENIED")
            }
            permissionCallbackContext = null
        }
    }

    private fun enqueueDownload(record: JSONObject, callbackContext: CallbackContext) {
        cordova.threadPool.execute {
            val sharedPref = cordova.context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val encryptDatabase = sharedPref.getBoolean(KEY_ENCRYPT_DATABASE, false)
            var db: SQLiteDatabase? = null
            try {
                db = DatabaseHelper.getWritableDatabase(cordova.context, encryptDatabase)
                
                var id = record.optString("id", "")
                if (id.isEmpty()) {
                    id = java.util.UUID.randomUUID().toString()
                }
                val endpoint = record.optString("endpoint", "")
                val payload = record.optString("payload", "")
                val filePath = record.optString("filePath", "")
                val downloadStrategy = record.optString("downloadStrategy", "REST_PAYLOAD")

                var resolvedPath = filePath
                if (filePath.isNotEmpty()) {
                    try {
                        val fileUri = android.net.Uri.parse(filePath)
                        val resolvedFile = webView.resourceApi.mapUriToFile(fileUri)
                        if (resolvedFile != null) {
                            resolvedPath = resolvedFile.absolutePath
                        }
                    } catch (e: Exception) {
                        // Fallback to original
                    }
                }

                val values = ContentValues().apply {
                    put("Id", id)
                    put("Endpoint", endpoint)
                    put("Payload", payload)
                    if (resolvedPath.isNotEmpty()) put("FilePath", resolvedPath)
                    put("DownloadStrategy", downloadStrategy)
                    put("Status", "pending")
                }

                db.insertWithOnConflict("download_queue", null, values, SQLiteDatabase.CONFLICT_REPLACE)

                val result = JSONObject().apply {
                    put("id", id)
                    put("status", "pending")
                }
                callbackContext.success(result)
            } catch (e: Exception) {
                callbackContext.error("Failed to enqueue download: ${e.message}")
            } finally {
                db?.close()
            }
        }
    }

    private fun getQueuedDownloads(callbackContext: CallbackContext) {
        cordova.threadPool.execute {
            val sharedPref = cordova.context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val encryptDatabase = sharedPref.getBoolean(KEY_ENCRYPT_DATABASE, false)
            var db: SQLiteDatabase? = null
            try {
                db = DatabaseHelper.getWritableDatabase(cordova.context, encryptDatabase)
                val cursor = db.rawQuery(
                    "SELECT Id, Status, Error FROM download_queue WHERE LOWER(Status) = 'pending' OR LOWER(Status) = 'failed' ORDER BY Sequence ASC",
                    null
                )
                val result = JSONArray()
                while (cursor.moveToNext()) {
                    val row = JSONObject().apply {
                        put("id", cursor.getString(0))
                        put("status", cursor.getString(1))
                        put("error", cursor.getString(2) ?: "")
                    }
                    result.put(row)
                }
                cursor.close()
                callbackContext.success(result)
            } catch (e: Exception) {
                callbackContext.error("Failed to query queued downloads: ${e.message}")
            } finally {
                db?.close()
            }
        }
    }

    private fun getCompletedDownloads(options: JSONObject, callbackContext: CallbackContext) {
        cordova.threadPool.execute {
            val sharedPref = cordova.context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val encryptDatabase = sharedPref.getBoolean(KEY_ENCRYPT_DATABASE, false)
            val autoDeleteCompleted = sharedPref.getBoolean(KEY_AUTO_DELETE_COMPLETED, false)
            val limit = options.optInt("limit", -1)
            // When autoDeleteCompleted is true, each page is deleted as soon as it's read, so
            // the "next page" is always at offset 0 relative to what remains — a caller-supplied
            // offset > 0 would skip records that shifted down after the previous page's delete.
            val offset = if (autoDeleteCompleted) 0 else options.optInt("offset", 0)

            var query = "SELECT Id, Status, FilePath, ResponseData, DownloadStrategy FROM download_queue WHERE LOWER(Status) = 'completed' ORDER BY Sequence ASC"
            val selectLimit = if (limit > 0) limit + 1 else -1
            if (selectLimit > 0) {
                query += " LIMIT $selectLimit"
                if (offset > 0) {
                    query += " OFFSET $offset"
                }
            }

            var db: SQLiteDatabase? = null
            try {
                db = DatabaseHelper.getWritableDatabase(cordova.context, encryptDatabase)
                val cursor = db.rawQuery(query, null)
                val records = JSONArray()
                val idsToDelete = mutableListOf<String>()
                var count = 0
                var hasMore = false

                while (cursor.moveToNext()) {
                    val id = cursor.getString(0)
                    if (limit > 0 && count >= limit) {
                        hasMore = true
                        break
                    }
                    val row = JSONObject().apply {
                        put("id", id)
                        put("status", cursor.getString(1))
                        put("filePath", cursor.getString(2) ?: "")
                        put("responseData", cursor.getString(3) ?: "")
                        put("downloadStrategy", cursor.getString(4) ?: "REST_PAYLOAD")
                    }
                    records.put(row)
                    idsToDelete.add(id)
                    count++
                }
                cursor.close()

                if (autoDeleteCompleted && idsToDelete.isNotEmpty()) {
                    db.beginTransaction()
                    try {
                        for (id in idsToDelete) {
                            db.delete("download_queue", "Id = ?", arrayOf(id))
                        }
                        db.setTransactionSuccessful()
                    } finally {
                        db.endTransaction()
                    }
                }

                val response = JSONObject().apply {
                    put("records", records)
                    put("hasMore", hasMore)
                }
                callbackContext.success(response)
            } catch (e: Exception) {
                callbackContext.error("Failed to query completed downloads: ${e.message}")
            } finally {
                db?.close()
            }
        }
    }

    private fun removeDownloads(ids: JSONArray, callbackContext: CallbackContext) {
        cordova.threadPool.execute {
            val sharedPref = cordova.context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val encryptDatabase = sharedPref.getBoolean(KEY_ENCRYPT_DATABASE, false)
            var db: SQLiteDatabase? = null
            try {
                db = DatabaseHelper.getWritableDatabase(cordova.context, encryptDatabase)
                db.beginTransaction()
                for (i in 0 until ids.length()) {
                    val id = ids.getString(i)
                    db.delete("download_queue", "Id = ?", arrayOf(id))
                }
                db.setTransactionSuccessful()
                db.endTransaction()
                callbackContext.success("Downloads removed successfully.")
            } catch (e: Exception) {
                callbackContext.error("Failed to remove downloads: ${e.message}")
            } finally {
                db?.close()
            }
        }
    }

    private fun clearDownloadQueue(callbackContext: CallbackContext) {
        cordova.threadPool.execute {
            val sharedPref = cordova.context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val encryptDatabase = sharedPref.getBoolean(KEY_ENCRYPT_DATABASE, false)
            var db: SQLiteDatabase? = null
            try {
                db = DatabaseHelper.getWritableDatabase(cordova.context, encryptDatabase)
                db.delete("download_queue", null, null)
                callbackContext.success("Download queue cleared successfully.")
            } catch (e: Exception) {
                callbackContext.error("Failed to clear download queue: ${e.message}")
            } finally {
                db?.close()
            }
        }
    }

    private fun openDatabaseInspector(callbackContext: CallbackContext) {
        val intent = android.content.Intent(cordova.activity, DatabaseInspectorActivity::class.java)
        cordova.activity.startActivity(intent)
        callbackContext.success("Database inspector opened.")
    }

    private fun cancelSync(callbackContext: CallbackContext) {
        try {
            val workManager = WorkManager.getInstance(cordova.context)
            workManager.cancelUniqueWork(UNIQUE_WORK_NAME)
            callbackContext.success("Cancellation signal sent to Sync Engine.")
        } catch (e: Exception) {
            callbackContext.error("Failed to cancel sync task: ${e.message}")
        }
    }

    companion object {
        const val PREFS_NAME = "com.hfps.backgroundsync.prefs"
        const val KEY_SERVER_URL = "serverUrl"
        const val KEY_QUEUE_TABLE_NAME = "queueTableName"
        const val KEY_SYNC_ONLY_ON_WIFI = "syncOnlyOnWifi"
        const val KEY_SYNC_ONLY_WHEN_CHARGING = "syncOnlyWhenCharging"
        const val KEY_ENABLE_NOTIFICATIONS = "enableNotifications"
        const val KEY_AUTO_DELETE_COMPLETED = "autoDeleteCompleted"
        const val KEY_SHOW_DEBUG_LOGS = "showDebugLogs"
        const val KEY_ENCRYPT_DATABASE = "encryptDatabase"
        const val KEY_HEADERS = "headers"
        const val KEY_NOTIFICATION_TEXTS = "notificationTexts"
        const val KEY_STATUS_MAP = "statusMap"

        const val UNIQUE_WORK_NAME = "BackgroundSyncPluginWork"
        const val WORK_TAG = "hfps_sync"
        const val NOTIFICATION_REQUEST_CODE = 1003

        private var progressCallbackContext: CallbackContext? = null

        fun sendProgressUpdate(event: String, percentage: Int, completed: Int, total: Int, error: String? = null) {
            val context = progressCallbackContext ?: return
            
            val progressObj = JSONObject().apply {
                put("event", event)
                put("percentage", percentage)
                put("completedCount", completed)
                put("totalCount", total)
                if (error != null) {
                    put("error", error)
                }
            }

            val result = PluginResult(PluginResult.Status.OK, progressObj)
            result.keepCallback = true
            context.sendPluginResult(result)
        }
    }
}
