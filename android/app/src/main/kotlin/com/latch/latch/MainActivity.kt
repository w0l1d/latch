package com.latch.latch

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.util.Log
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

    private companion object {
        // The only authorities MediaStore.getMediaUri() is documented to accept.
        val MEDIA_URI_AUTHORITIES = setOf(
            ExternalStorageDocIds.AUTHORITY,
            "com.android.providers.media.documents",
        )
    }

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
                //
                // Some devices don't implement this properly and throw (or
                // silently fail to persist). That must not take the batch down
                // with it — an exception here would escape the activity-result
                // callback and leave the parked MethodChannel result unanswered
                // forever. The grant is still live for this process, so outputs
                // land in the right folder now; the next batch just asks again,
                // since existingTreeGrant reads the platform's persisted table
                // and reports a grant that didn't stick as absent.
                runCatching {
                    contentResolver.takePersistableUriPermission(
                        treeUri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or
                            Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                    )
                }
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
                                val initialDoc = call.argument<String>("initialDocUri")
                                runOnUiThread { launchOpenTree(initial, initialDoc, result) }
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
                            // Whether Android still holds a writable grant on this
                            // exact tree. Lets the app reuse a destination the user
                            // chose earlier for sources whose folder can't be
                            // resolved, without ever TRUSTING a remembered URI: the
                            // platform's own table is still the authority.
                            "isTreeGrantLive" -> {
                                val uri = call.argument<String>("uri")!!
                                runOnUiThread { result.success(isTreeGrantLive(uri)) }
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
    // anything else (cloud providers) returns null and the caller falls back
    // to the Downloads default. Paths come from the document's own metadata —
    // the path-shaped externalstorage ids, or the MediaStore row behind
    // Downloads' msf: ids and the picker's media shortcuts — never from a
    // filesystem stat, which scoped storage denies for non-media files on
    // API 30+. Row-id steps query the document's own columns first (backed by
    // the URI grant) and only then the MediaStore table, which scoped storage
    // ownership-filters on API 29+ — the table can miss a file another app
    // owns (e.g. anything downloaded by Chrome). The provider→step decision
    // table lives in DocumentPathResolver (framework-free, JVM-pinned); this
    // executes the returned step.
    private fun resolveToFilePath(uri: Uri): String? {
        if (uri.scheme == "file") return uri.path
        if (!DocumentsContract.isDocumentUri(this, uri)) return null
        val docId = DocumentsContract.getDocumentId(uri)
        val step = DocumentPathResolver.plan(
            authority = uri.authority,
            docId = docId,
            apiLevel = Build.VERSION.SDK_INT,
            primaryRoot = primaryRoot(),
        )
        Log.i(
            "LatchSaf",
            "resolvePath ${uri.authority} / $docId -> ${step.javaClass.simpleName}",
        )
        return when (step) {
            is DocumentPathResolver.Step.Direct -> step.path
            is DocumentPathResolver.Step.QueryDocumentThenById ->
                // The media-documents provider's own document columns (queried
                // directly) don't expose RELATIVE_PATH/DATA — those overlap
                // with DocumentsContract's own columns only in name, not
                // content, so they come back null. MediaStore.getMediaUri()
                // is the documented bridge: it maps this SAME granted
                // document Uri to its underlying MediaStore content Uri,
                // and querying THAT Uri is backed by the per-URI grant, not
                // ownership — unlike a table query by id, which is
                // ownership-filtered on API 29+ and misses files the app
                // doesn't own (e.g. anything downloaded by Chrome).
                queryMediaStoreUriColumns(uri)
                    ?: queryDocumentColumns(uri)
                    ?: queryMediaPath(step.collection, step.id)
            is DocumentPathResolver.Step.QueryDocument -> queryDocumentColumns(uri)
            is DocumentPathResolver.Step.Unknown -> null
        }
    }

    private fun primaryRoot(): String =
        Environment.getExternalStorageDirectory().absolutePath

    private fun collectionUri(collection: DocumentPathResolver.Collection): Uri {
        @Suppress("DEPRECATION") // the string overload is the all-API way here
        return when (collection) {
            DocumentPathResolver.Collection.DOWNLOADS ->
                MediaStore.Downloads.EXTERNAL_CONTENT_URI
            DocumentPathResolver.Collection.IMAGES ->
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            DocumentPathResolver.Collection.VIDEO ->
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            DocumentPathResolver.Collection.AUDIO ->
                MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
            DocumentPathResolver.Collection.FILES ->
                MediaStore.Files.getContentUri("external")
        }
    }

    // Raw column values of the MediaStore row with this id in [collection], or
    // null when the row is gone or not queryable.
    private fun mediaRow(
        collection: DocumentPathResolver.Collection,
        id: String,
    ): Map<String, String?>? {
        return try {
            contentResolver.query(
                collectionUri(collection),
                arrayOf(
                    MediaStore.MediaColumns.RELATIVE_PATH,
                    MediaStore.MediaColumns.DISPLAY_NAME,
                    MediaStore.MediaColumns.DATA,
                    MediaStore.MediaColumns.VOLUME_NAME,
                ),
                "${MediaStore.MediaColumns._ID}=?",
                arrayOf(id),
                null,
            )?.use { c ->
                if (!c.moveToFirst()) return@use null
                rowColumns(c)
            }
        } catch (e: Exception) {
            null
        }
    }

    // Raw column values of the picked document itself. Backed by the URI grant,
    // so — unlike [mediaRow] — it is not ownership-filtered and works for files
    // the app doesn't own (e.g. anything downloaded by Chrome).
    private fun documentColumns(uri: Uri): Map<String, String?>? {
        return try {
            contentResolver.query(
                uri,
                arrayOf(
                    MediaStore.MediaColumns.RELATIVE_PATH,
                    MediaStore.MediaColumns.DISPLAY_NAME,
                    MediaStore.MediaColumns.DATA,
                    MediaStore.MediaColumns.VOLUME_NAME,
                ),
                null,
                null,
                null,
            )?.use { c ->
                if (!c.moveToFirst()) return@use null
                rowColumns(c)
            }
        } catch (e: Exception) {
            null
        }
    }

    private fun rowColumns(c: android.database.Cursor): Map<String, String?> = mapOf(
        "relative_path" to column(c, MediaStore.MediaColumns.RELATIVE_PATH),
        "display_name" to column(c, MediaStore.MediaColumns.DISPLAY_NAME),
        "data" to column(c, MediaStore.MediaColumns.DATA),
        "volume_name" to column(c, MediaStore.MediaColumns.VOLUME_NAME),
    )

    // A filesystem path from raw column values: RELATIVE_PATH + DISPLAY_NAME
    // (API 29+, where _data is hidden for files the app doesn't own) or _data
    // (older APIs / app-owned rows). Non-primary volumes (SD cards) mount under
    // /storage/<volume>, so VOLUME_NAME is respected when present. Null when no
    // path can be derived — the caller treats the source folder as unknown and
    // asks the user where to save.
    private fun pathFromColumns(cols: Map<String, String?>?): String? {
        if (cols == null) return null
        val rel = cols["relative_path"]
        val name = cols["display_name"]
        if (rel != null && name != null) {
            val root = cols["volume_name"]
                ?.takeIf { it.isNotEmpty() && it != MediaStore.VOLUME_EXTERNAL_PRIMARY }
                ?.let { "/storage/$it" } ?: primaryRoot()
            return DocumentPathResolver.joinPath(root, rel, name)
        }
        return cols["data"]
    }

    // The filesystem path of MediaStore row [id] in [collection]. Null when the
    // row is gone or no path can be derived.
    private fun queryMediaPath(
        collection: DocumentPathResolver.Collection,
        id: String,
    ): String? = pathFromColumns(mediaRow(collection, id))

    // Last resort for providers that front real files but don't encode the path
    // in their document id — unknown/OEM providers, and Downloads' `msf:` ids
    // before Q. Never stats the filesystem — a denied stat proves nothing about
    // the file's existence.
    private fun queryDocumentColumns(uri: Uri): String? =
        pathFromColumns(documentColumns(uri))

    // Maps a granted document Uri to its underlying MediaStore content Uri
    // (API 26+). Querying that Uri is backed by the specific per-Uri grant the
    // picker handed us, not by row ownership, so it works for files the app
    // doesn't own where a direct document-columns query returns nulls.
    //
    // getMediaUri() is documented to accept ExternalStorageProvider and
    // MediaDocumentsProvider Uris ONLY. DownloadsProvider (`msf:` ids) is a
    // different authority and out of contract, so it is not attempted — there
    // is no supported way to recover a path for those, and the caller asks the
    // user where to save instead.
    private fun mediaStoreUri(uri: Uri): Uri? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return null
        if (uri.authority !in MEDIA_URI_AUTHORITIES) return null
        return try {
            MediaStore.getMediaUri(this, uri)
        } catch (e: Exception) {
            null
        }
    }

    private fun queryMediaStoreUriColumns(uri: Uri): String? =
        mediaStoreUri(uri)?.let { pathFromColumns(documentColumns(it)) }

    private fun column(c: android.database.Cursor, name: String): String? {
        val idx = c.getColumnIndex(name)
        return if (idx >= 0) c.getString(idx) else null
    }

    // Launch the folder picker and park [result] for the callback.
    //
    // Seeding, in order: a path we resolved (points the picker straight at that
    // folder), else the picked document's own content:// URI. That second seed
    // is the only one available for the providers whose folder can't be
    // resolved at all (the picker's Downloads/Images/Videos shortcuts), and it
    // works because EXTRA_INITIAL_URI accepts a *document* URI and the system's
    // document navigator resolves its parent for us — DocumentsUI is privileged
    // and holds MANAGE_DOCUMENTS, so it can do the child→parent lookup this app
    // provably cannot. Without it those sources open the picker at the storage
    // root and the user has to find the folder by hand.
    //
    // Both seeds are best-effort by contract ("the initial location is system
    // specific if ... document navigator failed to locate the desired initial
    // location"), and some OEM pickers ignore the extra outright. A seed that
    // is ignored costs nothing — the picker opens where it would have anyway —
    // so nothing here may depend on it having worked.
    private fun launchOpenTree(
        initialPath: String?,
        initialDocUri: String?,
        result: MethodChannel.Result,
    ) {
        if (pendingTreeResult != null) {
            result.error("saf_busy", "a folder picker is already open", null)
            return
        }
        pendingTreeResult = result
        val seed = initialPath?.let { initialTreeUri(it) }
            ?: initialDocUri?.let { runCatching { Uri.parse(it) }.getOrNull() }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
            )
            seed?.let { putExtra(DocumentsContract.EXTRA_INITIAL_URI, it) }
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
    // front a real folder. No existence check: scoped storage hides non-media
    // paths from direct stat on API 30+, and a stale grant (folder deleted) is
    // caught anyway at createDocument time — the write fails and the caller
    // falls back to Downloads with a notice.
    private fun treeUriToPath(treeUri: Uri): String? {
        if (treeUri.authority != ExternalStorageDocIds.AUTHORITY) return null
        return ExternalStorageDocIds.toPath(
            DocumentsContract.getTreeDocumentId(treeUri),
            primaryRoot(),
        )
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

    // Whether Android still holds a writable persisted grant on this exact
    // tree URI. The platform table stays the single source of truth, so a
    // remembered URI whose grant the user has since revoked reports false and
    // the app asks again instead of silently failing to write.
    private fun isTreeGrantLive(treeUri: String): Boolean {
        val target = Uri.parse(treeUri)
        return contentResolver.persistedUriPermissions.any {
            it.isWritePermission && it.uri == target
        }
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
