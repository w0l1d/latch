package com.latch.latch

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The path ↔ document-id mapping the whole "save beside the original" flow
 * rests on. `toPath` decides whether a folder grant matches a source folder;
 * `toDocId` decides whether the folder picker opens at the source folder or at
 * the storage root. Both are invisible in a build — a wrong answer just sends
 * files somewhere unexpected — so every volume shape is pinned here, and the
 * round-trip tests pin the two directions against each other.
 */
class ExternalStorageDocIdsTest {

    private val primary = "/storage/emulated/0"

    // --- toDocId: path → document id -------------------------------------

    @Test
    fun `primary volume subfolder`() {
        assertEquals("primary:Documents/Work", ExternalStorageDocIds.toDocId("$primary/Documents/Work", primary))
    }

    @Test
    fun `primary volume root`() {
        assertEquals("primary:", ExternalStorageDocIds.toDocId(primary, primary))
    }

    @Test
    fun `trailing slash is not a folder named empty`() {
        assertEquals("primary:Documents", ExternalStorageDocIds.toDocId("$primary/Documents/", primary))
    }

    @Test
    fun `the sdcard symlink is the primary volume`() {
        assertEquals("primary:Download", ExternalStorageDocIds.toDocId("/sdcard/Download", primary))
        assertEquals("primary:", ExternalStorageDocIds.toDocId("/sdcard", primary))
    }

    @Test
    fun `the storage self primary symlink is the primary volume`() {
        assertEquals("primary:DCIM", ExternalStorageDocIds.toDocId("/storage/self/primary/DCIM", primary))
    }

    @Test
    fun `a removable FAT volume keeps its id verbatim`() {
        assertEquals("1A2B-3C4D:Photos", ExternalStorageDocIds.toDocId("/storage/1A2B-3C4D/Photos", primary))
        assertEquals("1A2B-3C4D:", ExternalStorageDocIds.toDocId("/storage/1A2B-3C4D", primary))
    }

    @Test
    fun `a long-uuid volume is addressable too, not only FAT ids`() {
        // Adopted/ext storage mounts under a full UUID. An earlier version only
        // matched XXXX-XXXX and left the picker unseeded on these devices.
        val uuid = "b7f3c0de-1234-4a5b-9c8d-0123456789ab"
        assertEquals("$uuid:Work", ExternalStorageDocIds.toDocId("/storage/$uuid/Work", primary))
    }

    @Test
    fun `a path on no served volume has no document id`() {
        assertNull(ExternalStorageDocIds.toDocId("/data/user/0/com.latch.latch/cache/x", primary))
        assertNull(ExternalStorageDocIds.toDocId("/storage", primary))
        assertNull(ExternalStorageDocIds.toDocId("relative/path", primary))
    }

    @Test
    fun `another user profile's volume is not addressable`() {
        // /storage/emulated/10 is a different profile: reachable as a path but
        // not as a document id of THIS user's externalstorage provider.
        assertNull(ExternalStorageDocIds.toDocId("/storage/emulated/10/Documents", primary))
        assertNull(ExternalStorageDocIds.toDocId("/storage/self/other", primary))
    }

    @Test
    fun `a prefix that is not a path boundary is not the primary volume`() {
        // "/storage/emulated/0abc" must not be read as "/storage/emulated/0" + "abc".
        assertNull(ExternalStorageDocIds.toDocId("/storage/emulated/0abc/Docs", primary))
    }

    // --- toPath: document id → path --------------------------------------

    @Test
    fun `primary document id resolves under the primary root`() {
        assertEquals("$primary/Documents/Work", ExternalStorageDocIds.toPath("primary:Documents/Work", primary))
        assertEquals(primary, ExternalStorageDocIds.toPath("primary:", primary))
    }

    @Test
    fun `primary is matched case-insensitively as the framework writes it`() {
        assertEquals("$primary/Docs", ExternalStorageDocIds.toPath("PRIMARY:Docs", primary))
    }

    @Test
    fun `a non-primary volume mounts under storage`() {
        assertEquals("/storage/1A2B-3C4D/Photos", ExternalStorageDocIds.toPath("1A2B-3C4D:Photos", primary))
        assertEquals("/storage/1A2B-3C4D", ExternalStorageDocIds.toPath("1A2B-3C4D:", primary))
    }

    @Test
    fun `a document id that is not path-shaped has no path`() {
        // Downloads' msf:/raw: ids and MediaStore ids reach this only by
        // mistake; they must not resolve to a plausible-looking folder.
        assertNull(ExternalStorageDocIds.toPath("12345", primary))
        assertNull(ExternalStorageDocIds.toPath(":Documents", primary))
    }

    // --- the two directions must be exact inverses -----------------------

    @Test
    fun `every served volume shape round-trips path to id to path`() {
        val paths = listOf(
            primary,
            "$primary/Download",
            "$primary/Documents/Work/Q3",
            "/storage/1A2B-3C4D",
            "/storage/1A2B-3C4D/Photos/2026",
            "/storage/b7f3c0de-1234-4a5b-9c8d-0123456789ab/Work",
        )
        for (path in paths) {
            val docId = ExternalStorageDocIds.toDocId(path, primary)
                ?: throw AssertionError("no document id for $path")
            assertEquals(path, ExternalStorageDocIds.toPath(docId, primary))
        }
    }

    @Test
    fun `the sdcard alias round-trips to the canonical primary path`() {
        // Not identity: the alias resolves to the real mount point, which is
        // what grant matching compares against.
        val docId = ExternalStorageDocIds.toDocId("/sdcard/Download", primary)
        assertEquals("$primary/Download", ExternalStorageDocIds.toPath(docId!!, primary))
    }

    @Test
    fun `a secondary user's primary root round-trips`() {
        // getExternalStorageDirectory() is per-profile, so the primary root is
        // not always /storage/emulated/0.
        val alt = "/storage/emulated/10"
        val docId = ExternalStorageDocIds.toDocId("$alt/Documents", alt)
        assertEquals("primary:Documents", docId)
        assertEquals("$alt/Documents", ExternalStorageDocIds.toPath(docId!!, alt))
    }
}
