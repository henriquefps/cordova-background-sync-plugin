package com.hfps.backgroundsync

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.view.ViewGroup
import android.webkit.JavascriptInterface
import android.webkit.WebView
import android.widget.Toast
import net.zetetic.database.sqlcipher.SQLiteDatabase
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

    private fun tableToJsonArray(db: SQLiteDatabase, table: String): JSONArray {
        val cursor = db.rawQuery("SELECT * FROM $table ORDER BY Sequence DESC", null)
        val result = JSONArray()
        while (cursor.moveToNext()) {
            val row = JSONObject()
            for (i in 0 until cursor.columnCount) {
                row.put(cursor.getColumnName(i), cursor.getString(i) ?: JSONObject.NULL)
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
                    "deleteSyncRecord" -> deleteRecord("sync_queue", args.getString("id"))
                    "deleteDownloadRecord" -> deleteRecord("download_queue", args.getString("id"))
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
