package icu.ringona.musereader

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    companion object {
        private const val FILE_CHANNEL = "com.musereader/files"
        private const val ENGINE_CHANNEL = "com.musereader/musescore_engine"
        private const val CONTROLS_CHANNEL = "com.musereader/controls"
        private const val MEDIA_CHANNEL = "com.musereader/media"
        private const val PICK_SCORE_REQUEST = 4101
        private const val PICK_FOLDER_REQUEST = 4102
        private const val NOTIFICATION_PERMISSION_REQUEST = 4103
        private const val IMPORT_DIRECTORY = "muse_reader/imports"
        private const val FOLDER_PREFS = "muse_reader_folder"
        private const val DISPLAY_PREFS = "muse_reader_display"
        private const val KEY_TREE_URI = "granted_tree_uri"
        private const val TAG = "MuseReaderAudio"
        private val SCORE_EXTENSIONS = setOf("mscx", "mscz")
        private const val LIBRARY_SIDECAR_SUFFIX = ".musereader-library-v1.json"
        private val SIDECAR_SUFFIXES = listOf(
            ".musereader-library-v1.json",
            ".musereader-cover-v1.png",
            ".musereader-document-v1.json.gz",
        )
        private val AUDIO_EXTENSIONS = setOf(
            "mp3", "wav", "wave", "ogg", "oga", "opus", "flac",
            "m4a", "aac", "mp4", "m4b", "wma", "aif", "aiff", "amr", "3gp",
        )
    }

    private var pendingFileResult: MethodChannel.Result? = null
    private var pendingFolderResult: MethodChannel.Result? = null
    private var controlsChannel: MethodChannel? = null
    private lateinit var mediaPlayer: MediaAudioPlayer
    private var renderWakeLock: android.os.PowerManager.WakeLock? = null
    private var screenReceiver: android.content.BroadcastReceiver? = null
    private var notificationPermissionAsked = false
    private lateinit var fallbackSynth: SimpleScoreSynth
    private lateinit var fluidSynth: FluidScoreSynth
    private val engineExecutor = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        fallbackSynth = SimpleScoreSynth()
        fluidSynth = FluidScoreSynth()
        fluidSynth.onScoreCompleted = {
            runOnUiThread {
                runCatching { controlsChannel?.invokeMethod("scoreCompleted", null) }
            }
        }
        val engineAvailable = NativeMuseScoreEngine.isAvailable()
        val engineReady = engineAvailable && NativeMuseScoreEngine.initialize()

        // Platform -> Flutter commands: the notification's stop action and
        // Android memory-pressure hints.
        val controls = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CONTROLS_CHANNEL)
        controlsChannel = controls
        PlaybackService.pauseRequest = {
            runOnUiThread {
                runCatching { controls.invokeMethod("pause", null) }
            }
        }

        // Audio-file playback (mp3/wav/ogg/flac/m4a/…). Engraved scores keep
        // using the MuseScore/FluidSynth engine channel.
        mediaPlayer = MediaAudioPlayer(this)
        mediaPlayer.onCompleted = {
            runOnUiThread {
                runCatching { controls.invokeMethod("mediaCompleted", null) }
            }
        }
        // 熄屏不打断下一首: the reader needs to know when the screen comes back
        // so it can preload the next piece and wait for the play button.
        registerScreenStateReceiver()
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MEDIA_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "load" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.success(
                                mapOf("available" to false, "error" to "音频路径为空"),
                            )
                        } else {
                            mediaPlayer.load(path) { payload -> result.success(payload) }
                        }
                    }
                    "play" -> {
                        val started = mediaPlayer.play()
                        if (started) {
                            requestNotificationPermissionIfNeeded()
                            PlaybackService.start(this@MainActivity)
                        }
                        result.success(started)
                    }
                    "pause" -> {
                        mediaPlayer.pause()
                        PlaybackService.stop(this@MainActivity)
                        result.success(null)
                    }
                    "stop" -> {
                        mediaPlayer.stop()
                        PlaybackService.stop(this@MainActivity)
                        result.success(null)
                    }
                    "seek" -> {
                        mediaPlayer.seekTo(
                            (call.argument<Number>("positionMs") ?: 0).toInt(),
                        )
                        result.success(null)
                    }
                    "position" -> result.success(mediaPlayer.positionMs())
                    "isPlaying" -> result.success(mediaPlayer.isPlaying())
                    "isInteractive" -> {
                        // 熄屏不打断下一首: the reader asks whether the screen is
                        // on at the moment a piece ends.
                        val manager = getSystemService(Context.POWER_SERVICE)
                            as android.os.PowerManager
                        result.success(manager.isInteractive)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FILE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickScoreFile" -> pickScoreFile(result)
                    "listImportedScoreFiles" -> result.success(
                        runCatching { listImportedScoreFiles() }.getOrDefault(emptyList()),
                    )
                    "storedScoreFolderTree" -> result.success(
                        folderPreferences().getString(KEY_TREE_URI, null),
                    )
                    "getBooleanPreference" -> result.success(
                        displayPreferences().getBoolean(
                            call.argument<String>("key") ?: "",
                            false,
                        ),
                    )
                    "setBooleanPreference" -> {
                        val key = call.argument<String>("key")
                        if (key.isNullOrBlank()) {
                            result.success(null)
                        } else {
                            displayPreferences().edit()
                                .putBoolean(key, call.argument<Boolean>("value") == true)
                                .apply()
                            result.success(null)
                        }
                    }
                    "readAudioMetadata" -> {
                        val paths = call.argument<List<String>>("paths") ?: emptyList()
                        engineExecutor.execute {
                            val payload = paths.map { path ->
                                runCatching { MediaAudioPlayer.readMetadata(path) }
                                    .getOrDefault(mapOf("path" to path))
                            }
                            runOnUiThread { result.success(payload) }
                        }
                    }
                    "pickScoreFolder" -> pickScoreFolder(result)
                    "listScoreFolderContents" -> {
                        val treeUri = call.argument<String>("treeUri")
                        val documentId = call.argument<String>("documentId") ?: ""
                        if (treeUri.isNullOrBlank()) {
                            result.error("folder_list_failed", "Missing treeUri.", null)
                        } else {
                            engineExecutor.execute {
                                val payload = runCatching {
                                    listScoreFolderContents(treeUri, documentId)
                                }
                                runOnUiThread {
                                    payload.fold(
                                        onSuccess = result::success,
                                        onFailure = {
                                            result.error(
                                                "folder_list_failed",
                                                it.message ?: "Cannot read the folder.",
                                                null,
                                            )
                                        },
                                    )
                                }
                            }
                        }
                    }
                    "importScoreFolder" -> {
                        val treeUri = call.argument<String>("treeUri")
                        val documentId = call.argument<String>("documentId") ?: ""
                        if (treeUri.isNullOrBlank()) {
                            result.error("folder_import_failed", "Missing treeUri.", null)
                        } else {
                            engineExecutor.execute {
                                val payload = runCatching {
                                    importScoreFolder(treeUri, documentId)
                                }
                                runOnUiThread {
                                    payload.fold(
                                        onSuccess = result::success,
                                        onFailure = {
                                            result.error(
                                                "folder_import_failed",
                                                it.message ?: "Cannot import the folder.",
                                                null,
                                            )
                                        },
                                    )
                                }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ENGINE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "open" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.success(
                                mapOf(
                                    "available" to engineAvailable,
                                    "error" to "The score path is empty.",
                                ),
                            )
                        } else if (!engineReady) {
                            result.success(
                                mapOf(
                                    "available" to engineAvailable,
                                    "error" to (
                                        NativeMuseScoreEngine.lastError()
                                            ?: "MuseScore native initialization failed."
                                    ),
                                ),
                            )
                        } else {
                            engineExecutor.execute {
                                acquireRenderWakeLock()
                                val json = try {
                                    NativeMuseScoreEngine.open(path)
                                } finally {
                                    releaseRenderWakeLock()
        screenReceiver?.let { runCatching { unregisterReceiver(it) } }
        screenReceiver = null
                                }
                                val response = if (json == null) {
                                    mapOf(
                                        "available" to engineAvailable,
                                        "error" to (
                                            NativeMuseScoreEngine.lastError()
                                                ?: "MuseScore native rendering failed."
                                        ),
                                    )
                                } else {
                                    try {
                                        mapOf(
                                            "available" to true,
                                            "document" to JSONObject(json).toPlatformValue(),
                                        )
                                    } catch (error: Exception) {
                                        mapOf(
                                            "available" to engineAvailable,
                                            "error" to (error.message ?: "Invalid native document"),
                                        )
                                    }
                                }
                                runOnUiThread { result.success(response) }
                            }
                        }
                    }
                    "startAudio" -> {
                        val events = call.argument<List<Any?>>("events") ?: emptyList()
                        val positionUs = (call.argument<Number>("positionUs") ?: 0).toLong()
                        val speed = (call.argument<Number>("speed") ?: 1.0).toDouble()
                        fallbackSynth.stop()
                        if (!fluidSynth.start(events, positionUs, speed)) {
                            Log.w(TAG, "Native FluidSynth unavailable; using oscillator fallback")
                            fallbackSynth.start(events, positionUs, speed)
                        }
                        // Keep audio and the auto-advance alive with the screen
                        // off / app backgrounded.
                        requestNotificationPermissionIfNeeded()
                        PlaybackService.start(this@MainActivity)
                        result.success(null)
                    }
                    "stopAudio" -> {
                        fluidSynth.stop()
                        fallbackSynth.stop()
                        PlaybackService.stop(this@MainActivity)
                        result.success(null)
                    }
                    "audioPositionUs" -> {
                        // Prefer the native track when available, but expose
                        // the same clock for the oscillator fallback.  A
                        // nullable result tells Flutter to use its local
                        // clock only while no Android audio track exists.
                        result.success(
                            fluidSynth.positionUs() ?: fallbackSynth.positionUs(),
                        )
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun pickScoreFile(result: MethodChannel.Result) {
        if (pendingFileResult != null) {
            result.error("picker_busy", "A file picker is already open.", null)
            return
        }
        pendingFileResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf(
                    "application/octet-stream",
                    "application/zip",
                    "text/xml",
                    "application/xml",
                    "audio/*",
                ),
            )
        }
        startActivityForResult(intent, PICK_SCORE_REQUEST)
    }

    private fun pickScoreFolder(result: MethodChannel.Result) {
        if (pendingFolderResult != null || pendingFileResult != null) {
            result.error("picker_busy", "A picker is already open.", null)
            return
        }
        pendingFolderResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
            )
        }
        startActivityForResult(intent, PICK_FOLDER_REQUEST)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            PICK_SCORE_REQUEST -> {
                val result = pendingFileResult
                pendingFileResult = null
                if (result == null) return
                if (resultCode != Activity.RESULT_OK || data?.data == null) {
                    result.success(null)
                    return
                }
                try {
                    result.success(copyToPersistentStorage(data.data!!))
                } catch (error: Exception) {
                    result.error("copy_failed", error.message, null)
                }
            }
            PICK_FOLDER_REQUEST -> {
                val result = pendingFolderResult
                pendingFolderResult = null
                if (result == null) return
                if (resultCode != Activity.RESULT_OK || data?.data == null) {
                    result.success(null)
                    return
                }
                try {
                    rememberFolderTree(data.data!!)
                    result.success(data.data.toString())
                } catch (error: Exception) {
                    result.error("folder_pick_failed", error.message, null)
                }
            }
        }
    }

    /**
     * Keep the tree grant for later app launches: with the persisted
     * permission the in-app directory browser can re-open the same folder
     * without asking the system picker again. A provider that refuses to
     * persist simply forces the picker on the next launch; the grant still
     * covers the current process either way.
     */
    private fun rememberFolderTree(uri: Uri) {
        runCatching {
            contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
        }
        folderPreferences().edit().putString(KEY_TREE_URI, uri.toString()).apply()
    }

    private fun folderPreferences() =
        getSharedPreferences(FOLDER_PREFS, Context.MODE_PRIVATE)

    private fun displayPreferences() =
        getSharedPreferences(DISPLAY_PREFS, Context.MODE_PRIVATE)

    /**
     * Keep imported scores in the app's files directory instead of cacheDir.
     * Android is allowed to clear cacheDir while the app is not running, which
     * made an imported score disappear even though it was still listed in the
     * in-memory Flutter library.
     */
    private fun copyToPersistentStorage(uri: Uri): String {
        val name = displayName(uri)
        val safeName = name.replace(Regex("[^A-Za-z0-9._-]"), "_")
        val directory = importedScoresDirectory()
        val target = uniqueImportTarget(directory, safeName)
        contentResolver.openInputStream(uri).use { input ->
            requireNotNull(input) { "Cannot open the selected file." }
            target.outputStream().use { output -> input.copyTo(output) }
        }
        return target.absolutePath
    }

    private fun uniqueImportTarget(directory: File, safeName: String): File {
        val timestamp = System.currentTimeMillis()
        var target = File(directory, "${timestamp}_$safeName")
        var suffix = 1
        while (target.exists()) {
            target = File(directory, "${timestamp}_${suffix}_$safeName")
            suffix += 1
        }
        return target
    }

    /**
     * Return persisted imports in newest-first order so the Flutter library
     * keeps the same ordering after a process restart.
     *
     * Versions before persistent storage wrote files below cacheDir. Migrate
     * those files on first read where they are still available.
     */
    private fun listImportedScoreFiles(): List<String> {
        migrateLegacyImports()
        return importedScoresDirectory()
            .listFiles()
            ?.filter { it.isFile && isSupportedScoreFile(it.name) }
            ?.sortedWith(
                compareByDescending<File> { it.lastModified() }
                    .thenByDescending { it.name },
            )
            ?.map { it.absolutePath }
            ?: emptyList()
    }

    /**
     * Import every valid file found DIRECTLY inside the folder of a granted
     * tree (non-recursive). The collection is replaced by this folder's files,
     * ordered by display name, and each copy carries a descending modification
     * time so the newest-first listing reproduces the import order after a
     * process restart.
     *
     * Files that are already imported with the same name and size are REUSED
     * in place instead of being re-copied: the metadata/cover/document sidecar
     * caches live next to them, so titles, authors, thumbnails and rendered
     * documents survive re-importing the same folder. The sidecar's stored
     * modification time is refreshed because the file's mtime is used for the
     * collection order.
     */
    private fun importScoreFolder(treeUriString: String, documentId: String): List<String> {
        val tree = Uri.parse(treeUriString)
        val directory = importedScoresDirectory()
        val children = treeChildren(tree, effectiveTreeDocumentId(tree, documentId))
            .filter { row ->
                row.mime != DocumentsContract.Document.MIME_TYPE_DIR &&
                    isSupportedScoreFile(row.displayName)
            }
            .sortedBy { row -> row.displayName.lowercase() }
        if (children.isEmpty()) {
            directory.listFiles()?.forEach { it.delete() }
            return emptyList()
        }

        val existing = directory.listFiles()
            ?.filter { it.isFile && isSupportedScoreFile(it.name) }
            ?.associateBy { cleanImportName(it.name) }
            ?: emptyMap()

        val base = System.currentTimeMillis()
        val imported = ArrayList<String>(children.size)
        val reused = HashSet<String>()
        children.forEachIndexed { index, row ->
            val safeName = row.displayName.replace(Regex("[^A-Za-z0-9._-]"), "_")
            val candidate = existing[safeName]
            val target = if (candidate != null &&
                !reused.contains(candidate.name) &&
                (row.size < 0L || candidate.length() == row.size)
            ) {
                // Same file, same size: keep it and its cached sidecars.
                candidate
            } else {
                val destination = File(directory, "${base - index}_$safeName")
                val childUri = DocumentsContract.buildDocumentUriUsingTree(
                    tree,
                    row.documentId,
                )
                contentResolver.openInputStream(childUri).use { input ->
                    requireNotNull(input) { "Cannot open ${row.displayName}." }
                    destination.outputStream().use { output -> input.copyTo(output) }
                }
                destination
            }
            reused += target.name
            // Some providers ignore setLastModified; the numeric name prefix
            // keeps the per-file identity unique across imports either way.
            target.setLastModified(base - index)
            refreshLibrarySidecar(target)
            imported += target.absolutePath
        }

        pruneImportedDirectory(directory, imported)
        return imported
    }

    /** Import-order prefix of a stored file: "1750000000000_alpha.mscx". */
    private fun cleanImportName(name: String): String =
        name.replace(Regex("^\\d{13}(?:_\\d+)?_"), "")

    /**
     * The library metadata sidecar records the source file's size and
     * modification time; keep the modification time in sync so reusing a file
     * (and therefore its cached title/cover) does not invalidate the cache.
     */
    private fun refreshLibrarySidecar(file: File) {
        val sidecar = File(file.parentFile, file.name + LIBRARY_SIDECAR_SUFFIX)
        if (!sidecar.isFile) return
        runCatching {
            val text = sidecar.readText()
            val updated = text.replace(
                Regex("\"sourceModifiedUs\"\\s*:\\s*\\d+"),
                "\"sourceModifiedUs\":${file.lastModified() * 1000}",
            )
            if (updated != text) sidecar.writeText(updated)
        }
    }

    /** Drop files that are no longer part of the collection, and orphan caches. */
    private fun pruneImportedDirectory(directory: File, keep: List<String>) {
        val keepPaths = keep.toHashSet()
        directory.listFiles()?.forEach { file ->
            val path = file.absolutePath
            if (keepPaths.contains(path)) return@forEach
            val basePath = SIDECAR_SUFFIXES
                .firstOrNull { path.endsWith(it) }
                ?.let { path.substring(0, path.length - it.length) }
            val isOrphanSidecar = basePath != null && !keepPaths.contains(basePath)
            val isDroppedMedia = basePath == null && isSupportedScoreFile(file.name)
            if (isOrphanSidecar || isDroppedMedia) file.delete()
        }
    }

    /**
     * A blank document id means "the root of the granted tree". Providers
     * cannot resolve "" as a parent document: the tree root must be addressed
     * by the tree's own document id (for example "primary:Download").
     */
    private fun effectiveTreeDocumentId(tree: Uri, documentId: String): String {
        if (documentId.isNotBlank()) return documentId
        return runCatching { DocumentsContract.getTreeDocumentId(tree) }
            .getOrDefault("")
    }

    /** Direct children of one folder inside a granted tree. */
    private fun treeChildren(tree: Uri, documentId: String): List<ChildRow> {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            tree,
            documentId,
        )
        val rows = mutableListOf<ChildRow>()
        contentResolver.query(
            childrenUri,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
                DocumentsContract.Document.COLUMN_SIZE,
            ),
            null,
            null,
            null,
        )?.use { cursor ->
            val idIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val nameIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            val mimeIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
            val sizeIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_SIZE)
            while (cursor.moveToNext()) {
                rows += ChildRow(
                    documentId = cursor.getString(idIndex) ?: "",
                    displayName = cursor.getString(nameIndex) ?: "",
                    mime = cursor.getString(mimeIndex) ?: "",
                    size = if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                        cursor.getLong(sizeIndex)
                    } else {
                        -1L
                    },
                )
            }
        }
        return rows
    }

    /** One row of a tree listing for the Flutter directory browser. */
    private data class ChildRow(
        val documentId: String,
        val displayName: String,
        val mime: String,
        val size: Long = -1L,
    )

    private fun listScoreFolderContents(
        treeUriString: String,
        documentId: String,
    ): Map<String, Any> {
        val tree = Uri.parse(treeUriString)
        val folders = mutableListOf<Map<String, Any>>()
        val scores = mutableListOf<String>()
        for (row in treeChildren(tree, effectiveTreeDocumentId(tree, documentId))) {
            if (row.mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                folders += mapOf(
                    "documentId" to row.documentId,
                    "name" to row.displayName,
                )
            } else if (isSupportedScoreFile(row.displayName)) {
                scores += row.displayName
            }
        }
        folders.sortBy { (it["name"] as String).lowercase() }
        scores.sortBy { it.lowercase() }
        return mapOf("folders" to folders, "scores" to scores)
    }

    private fun importedScoresDirectory(): File =
        File(filesDir, IMPORT_DIRECTORY).apply { mkdirs() }

    private fun migrateLegacyImports() {
        val legacyDirectory = File(cacheDir, IMPORT_DIRECTORY)
        if (!legacyDirectory.isDirectory) return
        val destination = importedScoresDirectory()
        legacyDirectory.listFiles()
            ?.filter { it.isFile && isSupportedScoreFile(it.name) }
            ?.forEach { source ->
                val target = File(destination, source.name)
                if (target.exists()) return@forEach
                // renameTo avoids a second copy when both directories are on
                // the same filesystem. Some devices/filesystems reject the
                // rename, so retain a copy fallback for those cases.
                if (!source.renameTo(target)) {
                    runCatching { source.copyTo(target, overwrite = false) }
                        .onFailure { target.delete() }
                }
            }
    }

    private fun isSupportedScoreFile(name: String): Boolean =
        isSupportedMediaFile(name)

    /** Scores and audio files the library can list and play. */
    private fun isSupportedMediaFile(name: String): Boolean {
        val extension = name.substringAfterLast('.', "").lowercase()
        return extension in SCORE_EXTENSIONS || extension in AUDIO_EXTENSIONS
    }

    private fun displayName(uri: Uri): String {
        var cursor: Cursor? = null
        try {
            cursor = contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            if (cursor != null && cursor.moveToFirst()) {
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0) return cursor.getString(index)
            }
        } finally {
            cursor?.close()
        }
        return uri.lastPathSegment ?: "score.mscx"
    }

    /**
     * Ask for POST_NOTIFICATIONS once (Android 13+). The playback foreground
     * service works without it, but the notification would stay hidden.
     */
    private fun requestNotificationPermissionIfNeeded() {
        if (notificationPermissionAsked) return
        if (android.os.Build.VERSION.SDK_INT < 33) return
        notificationPermissionAsked = true
        try {
            if (checkSelfPermission("android.permission.POST_NOTIFICATIONS") !=
                android.content.pm.PackageManager.PERMISSION_GRANTED
            ) {
                requestPermissions(
                    arrayOf("android.permission.POST_NOTIFICATIONS"),
                    NOTIFICATION_PERMISSION_REQUEST,
                )
            }
        } catch (error: Exception) {
            Log.w(TAG, "Unable to request the notification permission", error)
        }
    }

    private fun registerScreenStateReceiver() {
        if (screenReceiver != null) return
        val receiver = object : android.content.BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                val method = when (intent?.action) {
                    Intent.ACTION_SCREEN_ON -> "screenOn"
                    Intent.ACTION_SCREEN_OFF -> "screenOff"
                    else -> return
                }
                runCatching { controlsChannel?.invokeMethod(method, null) }
            }
        }
        val filter = android.content.IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
        }
        try {
            if (android.os.Build.VERSION.SDK_INT >= 33) {
                registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                registerReceiver(receiver, filter)
            }
            screenReceiver = receiver
        } catch (error: Exception) {
            Log.w(TAG, "Unable to observe the screen state", error)
        }
    }

    /**
     * Rendering a score is CPU work that must not be interrupted when the
     * screen is off and the app is in the background (the piece auto-advance
     * renders the next score before playing it). A short-timeout wake lock
     * covers exactly the render, independently of the playback service.
     */
    private fun acquireRenderWakeLock() {
        try {
            if (renderWakeLock?.isHeld != true) {
                val manager = getSystemService(Context.POWER_SERVICE)
                    as android.os.PowerManager
                renderWakeLock = manager
                    .newWakeLock(
                        android.os.PowerManager.PARTIAL_WAKE_LOCK,
                        "MuseReader:render",
                    )
                    .apply { setReferenceCounted(false) }
                renderWakeLock?.acquire(120_000L)
            }
        } catch (error: Exception) {
            Log.w(TAG, "Unable to acquire the render wake lock", error)
        }
    }

    private fun releaseRenderWakeLock() {
        val lock = renderWakeLock ?: return
        renderWakeLock = null
        runCatching { if (lock.isHeld) lock.release() }
    }

    /**
     * Android is short on memory: ask Flutter to release decoded images and,
     * for the strongest levels, every hydrated score document except the one
     * being displayed.
     */
    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        runOnUiThread {
            runCatching { controlsChannel?.invokeMethod("memoryPressure", level) }
        }
    }

    override fun onDestroy() {
        if (::fluidSynth.isInitialized) fluidSynth.stop()
        if (::fallbackSynth.isInitialized) fallbackSynth.stop()
        if (::mediaPlayer.isInitialized) mediaPlayer.stop()
        releaseRenderWakeLock()
        PlaybackService.pauseRequest = null
        PlaybackService.stop(this)
        engineExecutor.shutdownNow()
        super.onDestroy()
    }

    private fun JSONObject.toPlatformValue(): Map<String, Any?> {
        val result = linkedMapOf<String, Any?>()
        val keys = keys()
        while (keys.hasNext()) {
            val key = keys.next()
            result[key] = opt(key).toPlatformValue()
        }
        return result
    }

    private fun JSONArray.toPlatformValue(): List<Any?> =
        (0 until length()).map { opt(it).toPlatformValue() }

    private fun Any?.toPlatformValue(): Any? = when (this) {
        JSONObject.NULL -> null
        is JSONObject -> toPlatformValue()
        is JSONArray -> toPlatformValue()
        is Number -> this
        is Boolean -> this
        is String -> this
        else -> toString()
    }
}
