package com.hfps.backgroundsync

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.database.sqlite.SQLiteDatabase
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

object EncryptionHelper {
    private const val ANDROID_KEYSTORE = "AndroidKeyStore"
    private const val KEY_ALIAS = "BackgroundSyncPluginKeyAlias"
    private const val PREFS_NAME = "BackgroundSyncPluginEncryptionPrefs"
    private const val KEY_ENCRYPTED_DB_PASS = "encryptedDbPassword"
    private const val KEY_IV = "encryptionIv"

    @Synchronized
    fun getOrCreatePassphrase(context: Context): String {
        val sharedPrefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val encryptedPassBase64 = sharedPrefs.getString(KEY_ENCRYPTED_DB_PASS, null)
        val ivBase64 = sharedPrefs.getString(KEY_IV, null)

        if (encryptedPassBase64 != null && ivBase64 != null) {
            try {
                val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
                val secretKey = keyStore.getKey(KEY_ALIAS, null) as SecretKey
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                val iv = Base64.decode(ivBase64, Base64.NO_WRAP)
                cipher.init(Cipher.DECRYPT_MODE, secretKey, GCMParameterSpec(128, iv))
                val encryptedPass = Base64.decode(encryptedPassBase64, Base64.NO_WRAP)
                val decryptedPassBytes = cipher.doFinal(encryptedPass)
                return String(decryptedPassBytes, Charsets.UTF_8)
            } catch (e: Exception) {
                android.util.Log.e("BackgroundSyncPlugin", "Failed to decrypt passphrase, generating new one: ${e.message}")
            }
        }

        // Generate a new random passphrase and store it encrypted
        val rawPassphrase = java.util.UUID.randomUUID().toString()
        try {
            val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
            if (!keyStore.containsAlias(KEY_ALIAS)) {
                val keyGenerator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
                val spec = KeyGenParameterSpec.Builder(
                    KEY_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .build()
                keyGenerator.init(spec)
                keyGenerator.generateKey()
            }

            val secretKey = keyStore.getKey(KEY_ALIAS, null) as SecretKey
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, secretKey)
            val iv = cipher.iv
            val encryptedPass = cipher.doFinal(rawPassphrase.toByteArray(Charsets.UTF_8))

            sharedPrefs.edit()
                .putString(KEY_ENCRYPTED_DB_PASS, Base64.encodeToString(encryptedPass, Base64.NO_WRAP))
                .putString(KEY_IV, Base64.encodeToString(iv, Base64.NO_WRAP))
                .apply()
        } catch (e: Exception) {
            android.util.Log.e("BackgroundSyncPlugin", "Failed to store passphrase in Keystore: ${e.message}")
        }

        return rawPassphrase
    }
}

object DatabaseHelper {
    private const val DATABASE_NAME = "bg_sync.db"
    
    fun getDatabasePath(context: Context): File {
        return context.getDatabasePath(DATABASE_NAME)
    }

    @Synchronized
    fun getWritableDatabase(context: Context, encrypt: Boolean): SQLiteDatabase {
        val dbFile = getDatabasePath(context)
        val parentDir = dbFile.parentFile
        if (parentDir != null && !parentDir.exists()) {
            parentDir.mkdirs()
        }

        // nocipher build: SQLCipher is not bundled, so the database is always opened unencrypted.
        if (encrypt) {
            android.util.Log.w("BackgroundSyncPlugin", "encryptDatabase is not supported in the nocipher build; opening bg_sync.db unencrypted.")
        }

        try {
            val db = SQLiteDatabase.openOrCreateDatabase(dbFile, null)
            createTables(db)
            return db
        } catch (e: Exception) {
            android.util.Log.w("BackgroundSyncPlugin", "Failed to open database with current encryption state, recreating database. Error: ${e.message}")
            // Best-effort visibility: this wipes any unsynchronized queued records with no
            // recovery path, so surface it to the app (if a progress listener is registered)
            // instead of only logging to logcat, which production apps rarely monitor.
            BackgroundSyncPlugin.sendProgressUpdate("databaseReset", 0, 0, 0, e.message)
            if (dbFile.exists()) {
                dbFile.delete()
            }
            // Clear journal/wal files if any to prevent corruption on recreate
            val journalFile = File(dbFile.absolutePath + "-journal")
            if (journalFile.exists()) journalFile.delete()
            val walFile = File(dbFile.absolutePath + "-wal")
            if (walFile.exists()) walFile.delete()
            val shmFile = File(dbFile.absolutePath + "-shm")
            if (shmFile.exists()) shmFile.delete()

            val db = SQLiteDatabase.openOrCreateDatabase(dbFile, null)
            createTables(db)
            return db
        }
    }
    private fun createTables(db: SQLiteDatabase) {
        db.execSQL(
            """
            CREATE TABLE IF NOT EXISTS sync_queue (
                Id TEXT UNIQUE,
                Endpoint TEXT,
                Payload TEXT,
                FilePath TEXT,
                UploadStrategy TEXT,
                Status TEXT,
                Sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                Error TEXT
            )
            """.trimIndent()
        )
        db.execSQL(
            """
            CREATE TABLE IF NOT EXISTS download_queue (
                Id TEXT UNIQUE,
                Endpoint TEXT,
                Payload TEXT,
                FilePath TEXT,
                DownloadStrategy TEXT,
                Status TEXT,
                ResponseData TEXT,
                Sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                Error TEXT
            )
            """.trimIndent()
        )
    }
}
