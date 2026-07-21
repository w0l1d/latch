package com.latch.latch

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Environment
import android.provider.DocumentsContract
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

// local_auth's biometric prompt requires a FragmentActivity host — with a
// plain FlutterActivity every authenticate() call throws no_fragment_activity.
class MainActivity : FlutterFragmentActivity() {

    // ACTION_OPEN_DOCUMENT_TREE round-trips through an activity result, so the
    // pending MethodChannel result is parked here until the picker returns.
    private var pendingTreeResult: MethodChannel.Result? = null
    private lateinit var openTreeLauncher: ActivityResultLauncher<Intent>

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Must be registered before the activity is STARTED, hence onCreate.
        openTreeLauncher = registerForActivityResult(
            ActivityResultContracts.StartActivityForResult()
        ) { res ->
            val r = pendingTreeResult
            pendingTreeResult = null
            val treeUri = if (res.resultCode == RESULT_OK) res.data?.data else null
            if (treeUri != null) {
                // Persist the grant so it survives process death / restarts.
                contentResolver.takePersistableUriPermission(
                    treeUri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                )
                r?.success(treeUri.toString())
            } else {
                r?.success(null) // user cancelled or no data
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // SAF bridge: the file picker hands Dart a private cache COPY of each
        // selection; the user's real document is only reachable through its
        // content:// URI. These methods let in-place operations (rewrap,
        // share, shred, delete-originals) act on the actual file.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "latch/saf")
            .setMethodCallHandler { call, result ->
                // File IO off the main thread — write-back can copy large files.
                Thread {
                    try {
                        when (call.method) {
                            // Copy the (modified) cache file over the real document.
                            "writeBack" -> {
                                val uri = Uri.parse(call.argument<String>("uri")!!)
                                val path = call.argument<String>("path")!!
                                val out = contentResolver.openOutputStream(uri, "wt")
                                    ?: throw IllegalStateException("cannot open $uri for writing")
                                out.use { stream ->
                                    File(path).inputStream().use { it.copyTo(stream) }
                                    if (stream is FileOutputStream) stream.fd.sync()
                                }
                                runOnUiThread { result.success(null) }
                            }
                            // Overwrite the real document's first bytes (crypto-erase
                            // of the header) without truncating, then delete it.
                            "overwriteAndDelete" -> {
                                val uri = Uri.parse(call.argument<String>("uri")!!)
                                val bytes = call.argument<ByteArray>("bytes")!!
                                val pfd = contentResolver.openFileDescriptor(uri, "rw")
                                    ?: throw IllegalStateException("cannot open $uri read-write")
                                pfd.use {
                                    FileOutputStream(it.fileDescriptor).use { out ->
                                        out.write(bytes)
                                        out.fd.sync()
                                    }
                                }
                                DocumentsContract.deleteDocument(contentResolver, uri)
                                runOnUiThread { result.success(null) }
                            }
                            // Delete the real document (encrypt's delete-originals).
                            "delete" -> {
                                val uri = Uri.parse(call.argument<String>("uri")!!)
                                DocumentsContract.deleteDocument(contentResolver, uri)
                                runOnUiThread { result.success(null) }
                            }
                            // Best-effort content URI → filesystem path, so outputs
                            // can default to the folder the original lives in.
                            // Null when the provider doesn't expose a real path.
                            "resolvePath" -> {
                                val uri = Uri.parse(call.argument<String>("uri")!!)
                                val path = resolveToFilePath(uri)
                                runOnUiThread { result.success(path) }
                            }
                            // Ask the user to grant a folder (persistable tree URI)
                            // so the app can CREATE new output files there — the
                            // single-file picker only grants the picked document.
                            // Completes asynchronously via the activity-result
                            // callback; do NOT complete `result` here.
                            "openTree" -> {
                                val initial = call.argument<String>("initialPath")
                                runOnUiThread { launchOpenTree(initial, result) }
                            }
                            // Filesystem path a granted tree points at, so a grant
                            // can be matched to a source folder. Null for providers
                            // that don't front real files.
                            "treeUriToPath" -> {
                                val uri = Uri.parse(call.argument<String>("uri")!!)
                                runOnUiThread { result.success(treeUriToPath(uri)) }
                            }
                            // Create a new document in a granted tree and copy the
                            // staged file into it. Returns the new document URI and
                            // a human display path.
                            "createInTree" -> {
                                val treeUri = Uri.parse(call.argument<String>("treeUri")!!)
                                val displayName = call.argument<String>("displayName")!!
                                val mimeType = call.argument<String>("mimeType")
                                    ?: "application/octet-stream"
                                val srcPath = call.argument<String>("srcPath")!!
                                val created = createInTree(treeUri, displayName, mimeType, srcPath)
                                runOnUiThread { result.success(created) }
                            }
                            else -> runOnUiThread { result.notImplemented() }
                        }
                    } catch (e: Exception) {
                        runOnUiThread { result.error("saf_error", e.message, null) }
                    }
                }.start()
            }
    }

    // Only providers that genuinely front filesystem files are mapped;
    // anything else (media store, cloud providers) returns null and the
    // caller falls back to the Downloads default.
    private fun resolveToFilePath(uri: Uri): String? {
        if (uri.scheme == "file") return uri.path
        if (!DocumentsContract.isDocumentUri(this, uri)) return null
        val docId = DocumentsContract.getDocumentId(uri)
        return when (uri.authority) {
            "com.android.externalstorage.documents" -> {
                val split = docId.split(":", limit = 2)
                if (split.size != 2) return null
                val root = if (split[0].equals("primary", ignoreCase = true)) {
                    Environment.getExternalStorageDirectory().absolutePath
                } else {
                    "/storage/${split[0]}"
                }
                val file = File(root, split[1])
                if (file.exists()) file.absolutePath else null
            }
            "com.android.providers.downloads.documents" ->
                if (docId.startsWith("raw:")) docId.removePrefix("raw:") else null
            else -> null
        }
    }

    // Launch the folder picker, seeding it at [initialPath] when we can build an
    // externalstorage document URI for it, and park [result] for the callback.
    private fun launchOpenTree(initialPath: String?, result: MethodChannel.Result) {
        if (pendingTreeResult != null) {
            result.error("saf_busy", "a folder picker is already open", null)
            return
        }
        pendingTreeResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
            )
            initialPath?.let { p ->
                initialTreeUri(p)?.let { putExtra(DocumentsContract.EXTRA_INITIAL_URI, it) }
            }
        }
        try {
            openTreeLauncher.launch(intent)
        } catch (e: Exception) {
            pendingTreeResult = null
            result.error("saf_error", e.message, null)
        }
    }

    // Build a primary-storage document URI so the picker opens at [path].
    // Best-effort: only for paths under the primary external volume.
    private fun initialTreeUri(path: String): Uri? {
        val root = Environment.getExternalStorageDirectory().absolutePath
        if (!path.startsWith(root)) return null
        val rel = path.removePrefix(root).trim('/')
        val docId = if (rel.isEmpty()) "primary:" else "primary:$rel"
        return DocumentsContract.buildDocumentUri(
            "com.android.externalstorage.documents",
            docId,
        )
    }

    // Filesystem path a granted tree URI resolves to (mirrors resolveToFilePath
    // but on the TREE document id). Null when it doesn't front a real folder.
    private fun treeUriToPath(treeUri: Uri): String? {
        if (treeUri.authority != "com.android.externalstorage.documents") return null
        val docId = DocumentsContract.getTreeDocumentId(treeUri)
        val split = docId.split(":", limit = 2)
        if (split.size != 2) return null
        val root = if (split[0].equals("primary", ignoreCase = true)) {
            Environment.getExternalStorageDirectory().absolutePath
        } else {
            "/storage/${split[0]}"
        }
        val file = File(root, split[1])
        return if (file.exists()) file.absolutePath else null
    }

    // Create [displayName] in the granted [treeUri] (resolving collisions the
    // same way FileIoDart.resolveNameCollision does), then copy [srcPath] in.
    // Returns {uri, displayPath}. Deletes the new doc if the copy fails so a
    // partial file is never left behind.
    private fun createInTree(
        treeUri: Uri,
        displayName: String,
        mimeType: String,
        srcPath: String,
    ): Map<String, String> {
        val treeDocId = DocumentsContract.getTreeDocumentId(treeUri)
        val parent = DocumentsContract.buildDocumentUriUsingTree(treeUri, treeDocId)
        val finalName = uniquify(displayName, childDisplayNames(treeUri, treeDocId))
        val newUri = DocumentsContract.createDocument(contentResolver, parent, mimeType, finalName)
            ?: throw IllegalStateException("createDocument returned null for $finalName")
        try {
            val out = contentResolver.openOutputStream(newUri, "w")
                ?: throw IllegalStateException("cannot open $newUri for writing")
            out.use { stream ->
                File(srcPath).inputStream().use { it.copyTo(stream) }
                if (stream is FileOutputStream) stream.fd.sync()
            }
        } catch (e: Exception) {
            try {
                DocumentsContract.deleteDocument(contentResolver, newUri)
            } catch (_: Exception) {
            }
            throw e
        }
        val dir = treeUriToPath(treeUri)
        return mapOf(
            "uri" to newUri.toString(),
            "displayPath" to (if (dir != null) "$dir/$finalName" else finalName),
        )
    }

    // Existing child display names in a tree folder, for collision detection.
    private fun childDisplayNames(treeUri: Uri, treeDocId: String): Set<String> {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, treeDocId)
        val names = mutableSetOf<String>()
        contentResolver.query(
            children,
            arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null, null, null,
        )?.use { c ->
            while (c.moveToNext()) c.getString(0)?.let { names.add(it) }
        }
        return names
    }

    // Same rule as FileIoDart.resolveNameCollision: name, then name_2, name_3,
    // … up to 999, then a timestamp suffix. Extension is the last dot segment.
    private fun uniquify(name: String, taken: Set<String>): String {
        if (!taken.contains(name)) return name
        val dot = name.lastIndexOf('.')
        val base = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        for (n in 2 until 1000) {
            val candidate = "${base}_$n$ext"
            if (!taken.contains(candidate)) return candidate
        }
        return "${base}_${System.currentTimeMillis()}$ext"
    }
}
