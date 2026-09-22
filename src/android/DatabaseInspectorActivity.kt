package com.hfps.backgroundsync

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.view.ViewGroup
import android.webkit.JavascriptInterface
import android.webkit.WebView
import android.widget.Toast
import android.database.sqlite.SQLiteDatabase
import org.json.JSONArray
import org.json.JSONObject

/**
 * Standalone recovery/inspection screen for the plugin's private SQLite queue database.
 * Launched via the JS `openDatabaseInspector()` action; not part of the normal sync flow.
 */
class DatabaseInspectorActivity : Activity() {

    private lateinit var webView: WebView
    private var pendingExportJson: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        webView = WebView(this)
        webView.settings.javaScriptEnabled = true
        webView.layoutParams = ViewGroup.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT
        )
        webView.addJavascriptInterface(InspectorBridge(), "AndroidInspectorBridge")
        setContentView(webView)

        webView.loadUrl("file:///android_asset/inspector.html")
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != EXPORT_REQUEST_CODE) return

        val json = pendingExportJson
        pendingExportJson = null
        if (resultCode != Activity.RESULT_OK || json == null) return

        val uri = data?.data ?: return
        try {
            contentResolver.openOutputStream(uri)?.use { out ->
                out.write(json.toByteArray(Charsets.UTF_8))
            }
            Toast.makeText(this, "Export saved successfully.", Toast.LENGTH_SHORT).show()
        } catch (e: Exception) {
            Toast.makeText(this, "Export failed: ${e.message}", Toast.LENGTH_LONG).show()
        }
    }

    private fun isEncryptedDatabase(): Boolean {
        val sharedPref = getSharedPreferences(
            BackgroundSyncPlugin.PREFS_NAME,
            Context.MODE_PRIVATE
        )
        return sharedPref.getBoolean(BackgroundSyncPlugin.KEY_ENCRYPT_DATABASE, false)
    }

    private fun launchExportPicker(json: String) {
        pendingExportJson = json
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/json"
            putExtra(Intent.EXTRA_TITLE, "bg_sync_export_${System.currentTimeMillis()}.json")
        }
        startActivityForResult(intent, EXPORT_REQUEST_CODE)
    }

    /**
     * Columns that can legitimately hold large blobs of text (a base64 payload, a raw HTTP
     * error response body/page) — these are the only ones truncated for list/export views, so
     * short columns are never mangled even if something unexpectedly long ends up in them.
     */
    private val TRUNCATE_COLUMNS = setOf("Payload", "Error", "ResponseData")
    private val TRUNCATE_THRESHOLD = 1000
    private val TRUNCATE_HEAD = 400
    private val TRUNCATE_TAIL = 200

    private fun truncateForDisplay(value: String): String {
        if (value.length <= TRUNCATE_THRESHOLD) return value
        val omitted = value.length - TRUNCATE_HEAD - TRUNCATE_TAIL
        return value.substring(0, TRUNCATE_HEAD) +
            "\n...<TRUNCATED: $omitted of ${value.length} chars omitted — use \"View full\" to see everything>...\n" +
            value.substring(value.length - TRUNCATE_TAIL)
    }

    private fun tableToJsonArray(db: SQLiteDatabase, table: String, truncate: Boolean = true): JSONArray {
        val cursor = db.rawQuery("SELECT * FROM $table ORDER BY Sequence DESC", null)
        val result = JSONArray()
        while (cursor.moveToNext()) {
            val row = JSONObject()
            for (i in 0 until cursor.columnCount) {
                val colName = cursor.getColumnName(i)
                var value = cursor.getString(i)
                if (truncate && value != null && TRUNCATE_COLUMNS.contains(colName)) {
                    value = truncateForDisplay(value)
                }
                row.put(colName, value ?: JSONObject.NULL)
            }
            result.put(row)
        }
        cursor.close()
        return result
    }

    /**
     * Single synchronous entry point exposed to the bundled inspector.html page. Android's
     * WebView JS-interface calls run on a background thread (not the UI thread), so blocking
     * SQLite work here is safe and doesn't risk an ANR.
     */
    private inner class InspectorBridge {

        @JavascriptInterface
        fun invoke(action: String, argsJson: String): String {
            return try {
                val args = if (argsJson.isNotEmpty()) JSONObject(argsJson) else JSONObject()
                when (action) {
                    "getSyncQueue" -> withDatabase { db -> tableToJsonArray(db, "sync_queue").toString() }
                    "getDownloadQueue" -> withDatabase { db -> tableToJsonArray(db, "download_queue").toString() }
                    "getSyncRecordDetail" -> getRecordDetail("sync_queue", args.getString("id"))
                    "getDownloadRecordDetail" -> getRecordDetail("download_queue", args.getString("id"))
                    "deleteSyncRecord" -> deleteRecord("sync_queue", args.getString("id"))
                    "deleteDownloadRecord" -> deleteRecord("download_queue", args.getString("id"))
                    "retrySyncRecord" -> retryRecord("sync_queue", args.getString("id"))
                    "retryDownloadRecord" -> retryRecord("download_queue", args.getString("id"))
                    "getConfig" -> getConfig()
                    "exportAll" -> exportAll()
                    "close" -> {
                        runOnUiThread { finish() }
                        "{}"
                    }
                    else -> JSONObject().put("error", "Unknown action: $action").toString()
                }
            } catch (e: Exception) {
                JSONObject().put("error", e.message ?: "Unknown inspector error").toString()
            }
        }

        private fun withDatabase(block: (SQLiteDatabase) -> String): String {
            var db: SQLiteDatabase? = null
            return try {
                db = DatabaseHelper.getWritableDatabase(this@DatabaseInspectorActivity, isEncryptedDatabase())
                block(db)
            } finally {
                db?.close()
            }
        }

        private fun deleteRecord(table: String, id: String): String = withDatabase { db ->
            db.delete(table, "Id = ?", arrayOf(id))
            JSONObject().put("success", true).toString()
        }

        /**
         * Resets a stuck record back to `pending` and clears its last error, so the next
         * `sync()` run (SyncWorker selects WHERE Status IN ('pending', 'failed') already, but
         * this lets you force just ONE record back to a clean state to retry in isolation,
         * without waiting for/depending on whatever else is queued alongside it).
         */
        private fun retryRecord(table: String, id: String): String = withDatabase { db ->
            val values = android.content.ContentValues()
            values.put("Status", "pending")
            values.putNull("Error")
            val updated = db.update(table, values, "Id = ?", arrayOf(id))
            if (updated > 0) {
                JSONObject().put("success", true).toString()
            } else {
                JSONObject().put("error", "Record not found").toString()
            }
        }

        /** Untruncated single-row fetch, for the "View full" button on a truncated cell. */
        private fun getRecordDetail(table: String, id: String): String = withDatabase { db ->
            val cursor = db.rawQuery("SELECT * FROM $table WHERE Id = ? LIMIT 1", arrayOf(id))
            if (!cursor.moveToFirst()) {
                cursor.close()
                return@withDatabase JSONObject().put("error", "Record not found").toString()
            }
            val row = JSONObject()
            for (i in 0 until cursor.columnCount) {
                row.put(cursor.getColumnName(i), cursor.getString(i) ?: JSONObject.NULL)
            }
            cursor.close()
            row.toString()
        }

        /**
         * Current connection config — meant to catch exactly the class of bug that motivated
         * this: a misconfigured `ServerUrl`/`Endpoint` that only shows up as a cryptic native
         * HTTP error deep in a queue row, instead of being visible up front.
         */
        private fun getConfig(): String {
            val sharedPref = getSharedPreferences(BackgroundSyncPlugin.PREFS_NAME, Context.MODE_PRIVATE)
            val serverUrl = sharedPref.getString(BackgroundSyncPlugin.KEY_SERVER_URL, "") ?: ""
            val headersRaw = sharedPref.getString(BackgroundSyncPlugin.KEY_HEADERS, "{}") ?: "{}"
            val maskedHeaders = JSONObject()
            try {
                val headersObj = JSONObject(headersRaw)
                val keys = headersObj.keys()
                while (keys.hasNext()) {
                    val key = keys.next()
                    maskedHeaders.put(key, maskSecret(headersObj.optString(key)))
                }
            } catch (e: Exception) {
                // Leave maskedHeaders empty — surfaced as "no headers configured" in the UI.
            }
            return JSONObject()
                .put("serverUrl", serverUrl)
                .put("headers", maskedHeaders)
                .put("encryptDatabase", isEncryptedDatabase())
                .toString()
        }

        private fun maskSecret(value: String): String {
            if (value.length <= 8) return "****"
            return value.substring(0, 4) + "…" + value.substring(value.length - 4)
        }

        private fun exportAll(): String = withDatabase { db ->
            val export = JSONObject()
            export.put("syncQueue", tableToJsonArray(db, "sync_queue"))
            export.put("downloadQueue", tableToJsonArray(db, "download_queue"))
            val json = export.toString(2)
            runOnUiThread { launchExportPicker(json) }
            JSONObject().put("success", true).toString()
        }
    }

    companion object {
        private const val EXPORT_REQUEST_CODE = 9821
    }
}
