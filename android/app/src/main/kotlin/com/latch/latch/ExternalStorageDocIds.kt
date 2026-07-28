package com.latch.latch

/**
 * Path ↔ document-id mapping for the `com.android.externalstorage.documents`
 * provider, whose document ids are path-shaped: `"<volume>:<relative/path>"`.
 *
 * Three call sites need this mapping and need it to agree:
 *  - `resolvePath` / `treeUriToPath` turn a granted document into a real folder
 *    path, so a grant can be matched against a source folder;
 *  - `initialTreeUri` turns a source folder back into a document URI, so the
 *    folder picker opens *at* that folder instead of at the storage root.
 *
 * The two directions must be exact inverses. When they drift, output silently
 * lands in the wrong folder or the picker opens unseeded — both invisible in a
 * build and both already shipped once. So the logic lives here as pure Kotlin
 * (the primary volume's mount point is a parameter, not an `Environment` call)
 * and is pinned by round-trip unit tests in `ExternalStorageDocIdsTest`.
 */
object ExternalStorageDocIds {
    const val AUTHORITY = "com.android.externalstorage.documents"

    /** Symlinks to the primary volume that show up in real filesystem paths. */
    private val PRIMARY_ALIASES = listOf("/sdcard", "/storage/self/primary")

    /**
     * Filesystem path [docId] addresses, e.g. `"primary:Docs/Work"` →
     * `"<primaryRoot>/Docs/Work"`. Null when [docId] isn't path-shaped.
     *
     * A non-primary volume maps to `/storage/<volume>` — its mount point is the
     * volume id verbatim, so [toDocId] can recover the id without guessing at
     * its case or format.
     */
    fun toPath(docId: String, primaryRoot: String): String? {
        val split = docId.split(":", limit = 2)
        if (split.size != 2) return null
        val (volume, rel) = split
        if (volume.isEmpty()) return null
        val root = if (volume.equals("primary", ignoreCase = true)) {
            primaryRoot.trimEnd('/')
        } else {
            "/storage/$volume"
        }
        val sub = rel.trim('/')
        return if (sub.isEmpty()) root else "$root/$sub"
    }

    /**
     * Document id addressing [path], e.g. `"<primaryRoot>/Docs/Work"` →
     * `"primary:Docs/Work"`. Null when [path] is on no volume this provider
     * serves (an app-private dir, another user profile's `/storage/emulated/N`,
     * a cloud provider's pseudo-path), in which case the caller leaves the
     * picker unseeded.
     */
    fun toDocId(path: String, primaryRoot: String): String? {
        val target = path.trimEnd('/').ifEmpty { path }
        val roots = listOf(primaryRoot.trimEnd('/')) + PRIMARY_ALIASES
        for (root in roots) {
            if (root.isEmpty()) continue
            if (target == root) return "primary:"
            if (target.startsWith("$root/")) {
                return "primary:" + target.removePrefix("$root/").trim('/')
            }
        }
        // A removable/secondary volume: /storage/<volume>[/sub]. `emulated` and
        // `self` are the primary volume's own containers, already handled above
        // for THIS user — any other profile under them is not addressable.
        val m = Regex("^/storage/([^/]+)(?:/(.*))?$").find(target) ?: return null
        val volume = m.groupValues[1]
        if (volume == "emulated" || volume == "self") return null
        val sub = m.groupValues[2].trim('/')
        return if (sub.isEmpty()) "$volume:" else "$volume:$sub"
    }
}
