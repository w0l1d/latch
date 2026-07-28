package com.latch.latch

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
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
                            // A folder grant the user has ALREADY given that covers
                            // a folder — so the app asks only for folders it has no
                            // access to yet. Null when nothing covers it.
                            "existingTreeGrant" -> {
                                val folder = call.argument<String>("folder")!!
                                runOnUiThread { result.success(existingTreeGrant(folder)) }
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
                                val subPath = call.argument<String>("subPath") ?: ""
                                val created =
                                    createInTree(treeUri, displayName, mimeType, srcPath, subPath)
                                runOnUiThread { result.success(created) }
                            }
                            // Open the system file browser at a folder so the
                            // user can see the files they just locked/unlocked.
                            "openFolder" -> {
                                val treeUri = call.argument<String>("treeUri")
                                val path = call.argument<String>("path")
                                runOnUiThread { result.success(openFolder(treeUri, path)) }
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
            ExternalStorageDocIds.AUTHORITY -> existingPath(docId)
            "com.android.providers.downloads.documents" ->
                if (docId.startsWith("raw:")) docId.removePrefix("raw:") else dataColumnPath(uri)
            else -> dataColumnPath(uri)
        }
    }

    // The path an externalstorage document id addresses, but only if something
    // is actually there — a document id can outlive the file (SD card pulled,
    // folder deleted), and a path that doesn't exist would be matched against
    // source folders as if it were live.
    private fun existingPath(docId: String): String? {
        val path = ExternalStorageDocIds.toPath(docId, primaryRoot()) ?: return null
        return if (File(path).exists()) path else null
    }

    private fun primaryRoot(): String =
        Environment.getExternalStorageDirectory().absolutePath

    // Last resort for providers that front real files but don't encode the path
    // in their document id — Downloads' `msf:<id>` documents and MediaStore
    // documents both expose `_data`. Cloud/virtual providers don't, and then
    // this is null (caller treats the source folder as unknown).
    private fun dataColumnPath(uri: Uri): String? {
        return try {
            contentResolver.query(
                uri,
                arrayOf(MediaStore.MediaColumns.DATA),
                null,
                null,
                null,
            )?.use { c ->
                val idx = c.getColumnIndex(MediaStore.MediaColumns.DATA)
                if (idx < 0 || !c.moveToFirst()) return@use null
                val path = c.getString(idx) ?: return@use null
                if (File(path).exists()) path else null
            }
        } catch (e: Exception) {
            null
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

    // Build an externalstorage document URI so the picker opens at [path].
    // Best-effort: null for a path on no volume this provider serves, and the
    // picker then opens unseeded — as it also does on OEM pickers that ignore
    // EXTRA_INITIAL_URI regardless of what we pass.
    private fun initialTreeUri(path: String): Uri? {
        val docId = ExternalStorageDocIds.toDocId(path, primaryRoot()) ?: return null
        return DocumentsContract.buildDocumentUri(ExternalStorageDocIds.AUTHORITY, docId)
    }

    // Open the Documents UI / a file browser at a folder. Prefers a granted
    // tree URI (opens exactly that folder); otherwise builds a primary-storage
    // document URI from a filesystem path. Returns false when no activity can
    // handle it or the folder can't be addressed.
    private fun openFolder(treeUri: String?, path: String?): Boolean {
        val docUri: Uri = when {
            treeUri != null -> {
                val tree = Uri.parse(treeUri)
                DocumentsContract.buildDocumentUriUsingTree(
                    tree,
                    DocumentsContract.getTreeDocumentId(tree),
                )
            }
            path != null -> initialTreeUri(path) ?: return false
            else -> return false
        }
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(docUri, DocumentsContract.Document.MIME_TYPE_DIR)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        return try {
            startActivity(intent)
            true
        } catch (e: android.content.ActivityNotFoundException) {
            false
        }
    }

    // Filesystem path a granted tree URI resolves to (same mapping as
    // resolveToFilePath, but on the TREE document id). Null when it doesn't
    // front a real folder.
    private fun treeUriToPath(treeUri: Uri): String? {
        if (treeUri.authority != ExternalStorageDocIds.AUTHORITY) return null
        return existingPath(DocumentsContract.getTreeDocumentId(treeUri))
    }

    // A persisted folder grant that already covers [folderPath] — the folder
    // itself, or an ancestor of it (a tree grant can create documents in any
    // descendant). Returns {treeUri, subPath}, where subPath is the path from
    // the granted tree down to the folder ("" when the grant IS the folder), or
    // null when no grant covers it. Lets the app prompt only for folders it has
    // no write access to yet, including grants taken in an earlier session or
    // for a parent folder. The deepest covering grant wins.
    private fun existingTreeGrant(folderPath: String): Map<String, String>? {
        val target = folderPath.trimEnd('/')
        var bestRoot: String? = null
        var best: Map<String, String>? = null
        for (perm in contentResolver.persistedUriPermissions) {
            if (!perm.isWritePermission) continue
            val uri = perm.uri
            if (!DocumentsContract.isTreeUri(uri)) continue
            val root = (
                try {
                    treeUriToPath(uri)
                } catch (e: Exception) {
                    null
                }
                )?.trimEnd('/') ?: continue
            val sub = when {
                root == target -> ""
                target.startsWith("$root/") -> target.substring(root.length + 1)
                else -> continue
            }
            if (bestRoot == null || root.length > bestRoot.length) {
                bestRoot = root
                best = mapOf("treeUri" to uri.toString(), "subPath" to sub)
            }
        }
        return best
    }

    // Address a folder nested inside a granted tree. The externalstorage
    // provider's document ids are path-shaped ("primary:Docs"), so a descendant
    // is the tree's own id plus the relative path.
    private fun childDocId(treeDocId: String, subPath: String): String =
        if (treeDocId.endsWith(":") || treeDocId.endsWith("/")) {
            "$treeDocId$subPath"
        } else {
            "$treeDocId/$subPath"
        }

    // Create [displayName] in the granted [treeUri] (resolving collisions the
    // same way FileIoDart.resolveNameCollision does), then copy [srcPath] in.
    // [subPath] targets a folder nested inside the grant — empty means the tree
    // root. Returns {uri, displayPath}. Deletes the new doc if the copy fails so
    // a partial file is never left behind.
    private fun createInTree(
        treeUri: Uri,
        displayName: String,
        mimeType: String,
        srcPath: String,
        subPath: String,
    ): Map<String, String> {
        val treeDocId = DocumentsContract.getTreeDocumentId(treeUri)
        val parentDocId =
            if (subPath.isEmpty()) treeDocId else childDocId(treeDocId, subPath)
        val parent = DocumentsContract.buildDocumentUriUsingTree(treeUri, parentDocId)
        val finalName = uniquify(displayName, childDisplayNames(treeUri, parentDocId))
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
        val treeDir = treeUriToPath(treeUri)
        val dir = when {
            treeDir == null -> null
            subPath.isEmpty() -> treeDir
            else -> "${treeDir.trimEnd('/')}/$subPath"
        }
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
