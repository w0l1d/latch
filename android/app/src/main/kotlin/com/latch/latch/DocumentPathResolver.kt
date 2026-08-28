package com.latch.latch

/**
 * The decision table that turns a picked document into a filesystem path —
 * framework-free so it is unit-testable on the JVM (see
 * DocumentPathResolverTest). MainActivity executes the returned [Step].
 *
 * The picker's sidebar shortcuts are served by different providers than
 * tree-browsed folders, and only externalstorage encodes the path in the
 * document id:
 *
 *  - `com.android.externalstorage.documents` — path-shaped ids ("primary:Docs/Work").
 *  - `com.android.providers.downloads.documents` — `raw:` (the path itself) or
 *    `msf:` (a MediaStore Downloads row id, API 29+).
 *  - `com.android.providers.media.documents` — kind-prefixed MediaStore row ids
 *    (image:42, video:42, audio:42, document:42).
 *  - anything else (OEM/cloud providers) — no id format to rely on; the
 *    document's own columns are the only bet.
 *
 * MediaStore row ids resolve through RELATIVE_PATH + DISPLAY_NAME (API 29+),
 * the columns that survive scoped storage, where `_data` is hidden for files
 * the app doesn't own. Nothing here performs a filesystem stat: scoped storage
 * can deny the stat of a perfectly real file and falsely report the source
 * folder as unknown.
 *
 * Row ids are resolved document-first: query the picked document's OWN columns
 * (backed by the URI grant, so they work for files the app doesn't own), and
 * only fall back to a MediaStore table query by id — which scoped storage
 * ownership-filters to rows the app created, so it can miss a file another app
 * owns (e.g. anything downloaded by Chrome) unless the app holds broad read
 * permission. The order is part of the contract: the document query is the
 * grant-backed path, the table query is the fallback.
 */
object DocumentPathResolver {

    /** Which MediaStore table a provider's row id addresses. */
    enum class Collection { DOWNLOADS, IMAGES, VIDEO, AUDIO, FILES }

    /** One resolution step, executed by the caller. */
    sealed class Step {
        /** The id itself is the path — no query needed. */
        data class Direct(val path: String) : Step()

        /**
         * Query the document's own columns first (grant-backed), falling back
         * to a [collection] row query by id (ownership-filtered on API 29+).
         */
        data class QueryDocumentThenById(
            val collection: Collection,
            val id: String,
        ) : Step()

        /** Query the document's own columns (unknown/OEM providers, pre-Q msf). */
        data object QueryDocument : Step()

        /** Nothing this resolver knows how to map. */
        data object Unknown : Step()
    }

    /**
     * The step to take for [authority] + [docId] on API [apiLevel], with
     * [primaryRoot] as the primary volume's mount point. Pure: no framework
     * calls, so every provider shape is pinned by DocumentPathResolverTest.
     */
    fun plan(authority: String?, docId: String, apiLevel: Int, primaryRoot: String): Step {
        if (authority == null) return Step.Unknown
        return when (authority) {
            ExternalStorageDocIds.AUTHORITY ->
                ExternalStorageDocIds.toPath(docId, primaryRoot)
                    ?.let { Step.Direct(it) }
                    ?: Step.Unknown
            "com.android.providers.downloads.documents" -> when {
                docId.startsWith("raw:") -> Step.Direct(docId.removePrefix("raw:"))
                docId.startsWith("msf:") && apiLevel >= 29 ->
                    Step.QueryDocumentThenById(Collection.DOWNLOADS, docId.removePrefix("msf:"))
                else -> Step.QueryDocument
            }
            "com.android.providers.media.documents" -> {
                val parts = docId.split(":", limit = 2)
                if (parts.size == 2) {
                    val collection = when (parts[0].lowercase()) {
                        "image" -> Collection.IMAGES
                        "video" -> Collection.VIDEO
                        "audio" -> Collection.AUDIO
                        "document" -> Collection.FILES
                        else -> null
                    }
                    if (collection != null) Step.QueryDocumentThenById(collection, parts[1])
                    else Step.QueryDocument
                } else {
                    Step.QueryDocument
                }
            }
            else -> Step.QueryDocument
        }
    }

    /** RELATIVE_PATH + DISPLAY_NAME → absolute path under the volume root. */
    fun joinPath(volumeRoot: String, relativePath: String, displayName: String): String {
        val root = volumeRoot.trimEnd('/')
        val rel = relativePath.trim('/')
        return if (rel.isEmpty()) "$root/$displayName" else "$root/$rel/$displayName"
    }
}
