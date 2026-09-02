package com.latch.latch

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The decision table that turns a picked document into a filesystem path.
 *
 * The picker's sidebar shortcuts (Downloads, Images, Videos, Audio, Documents)
 * are served by different providers than the tree-browsed folders: Downloads
 * uses `msf:`/`raw:` ids, media uses kind-prefixed ids (`image:42`), and only
 * externalstorage uses path-shaped ids. A wrong answer here is invisible in a
 * build — the app just concludes it "can't tell which folder these files came
 * from" and asks the user — so every provider shape is pinned here.
 */
class DocumentPathResolverTest {

    private val primary = "/storage/emulated/0"

    // --- joinPath ----------------------------------------------------------

    @Test
    fun `a root-relative path joins directly under the primary root`() {
        assertEquals(
            "$primary/note.txt",
            DocumentPathResolver.joinPath(primary, "", "note.txt"),
        )
    }

    @Test
    fun `a downloads relative path joins under the primary root`() {
        assertEquals(
            "$primary/Download/doc.pdf",
            DocumentPathResolver.joinPath(primary, "Download/", "doc.pdf"),
        )
    }

    @Test
    fun `a nested relative path with stray slashes joins cleanly`() {
        assertEquals(
            "$primary/Docs/Work/note.txt",
            DocumentPathResolver.joinPath("$primary/", "/Docs/Work/", "note.txt"),
        )
    }

    // --- downloads provider ------------------------------------------------

    @Test
    fun `a raw downloads doc id is a direct path`() {
        assertEquals(
            DocumentPathResolver.Step.Direct("/storage/emulated/0/Download/x.txt"),
            DocumentPathResolver.plan(
                "com.android.providers.downloads.documents",
                "raw:/storage/emulated/0/Download/x.txt",
                apiLevel = 36,
                primaryRoot = primary,
            ),
        )
    }

    @Test
    fun `an msf downloads doc id resolves document columns first then the Downloads collection on API 29+`() {
        assertEquals(
            DocumentPathResolver.Step.QueryDocumentThenById(DocumentPathResolver.Collection.DOWNLOADS, "42"),
            DocumentPathResolver.plan(
                "com.android.providers.downloads.documents",
                "msf:42",
                apiLevel = 36,
                primaryRoot = primary,
            ),
        )
    }

    @Test
    fun `an msf downloads doc id falls back to the document columns before Q`() {
        assertEquals(
            DocumentPathResolver.Step.QueryDocument,
            DocumentPathResolver.plan(
                "com.android.providers.downloads.documents",
                "msf:42",
                apiLevel = 28,
                primaryRoot = primary,
            ),
        )
    }

    // --- media provider (picker shortcuts: Images/Videos/Audio/Documents) --

    @Test
    fun `image video audio and document kinds map to their collections`() {
        fun step(docId: String) =
            DocumentPathResolver.plan(
                "com.android.providers.media.documents",
                docId,
                apiLevel = 36,
                primaryRoot = primary,
            )

        assertEquals(
            DocumentPathResolver.Step.QueryDocumentThenById(DocumentPathResolver.Collection.IMAGES, "7"),
            step("image:7"),
        )
        assertEquals(
            DocumentPathResolver.Step.QueryDocumentThenById(DocumentPathResolver.Collection.VIDEO, "8"),
            step("video:8"),
        )
        assertEquals(
            DocumentPathResolver.Step.QueryDocumentThenById(DocumentPathResolver.Collection.AUDIO, "9"),
            step("audio:9"),
        )
        assertEquals(
            DocumentPathResolver.Step.QueryDocumentThenById(DocumentPathResolver.Collection.FILES, "10"),
            step("document:10"),
        )
    }

    @Test
    fun `an unknown media kind falls back to the document columns`() {
        assertEquals(
            DocumentPathResolver.Step.QueryDocument,
            DocumentPathResolver.plan(
                "com.android.providers.media.documents",
                "mystery:42",
                apiLevel = 36,
                primaryRoot = primary,
            ),
        )
    }

    @Test
    fun `a kindless media doc id falls back to the document columns`() {
        assertEquals(
            DocumentPathResolver.Step.QueryDocument,
            DocumentPathResolver.plan(
                "com.android.providers.media.documents",
                "42",
                apiLevel = 36,
                primaryRoot = primary,
            ),
        )
    }

    // --- externalstorage provider (regular tree-browsed folders) -----------

    @Test
    fun `a path-shaped externalstorage doc id is a direct path`() {
        assertEquals(
            DocumentPathResolver.Step.Direct("$primary/Docs/Work/note.txt"),
            DocumentPathResolver.plan(
                "com.android.externalstorage.documents",
                "primary:Docs/Work/note.txt",
                apiLevel = 36,
                primaryRoot = primary,
            ),
        )
    }

    @Test
    fun `a non-path-shaped externalstorage doc id is unknown`() {
        assertEquals(
            DocumentPathResolver.Step.Unknown,
            DocumentPathResolver.plan(
                "com.android.externalstorage.documents",
                "not-a-volume-id",
                apiLevel = 36,
                primaryRoot = primary,
            ),
        )
    }

    // --- anything else -----------------------------------------------------

    @Test
    fun `an unknown authority falls back to the document columns`() {
        assertEquals(
            DocumentPathResolver.Step.QueryDocument,
            DocumentPathResolver.plan(
                "com.some.oem.documents",
                "whatever",
                apiLevel = 36,
                primaryRoot = primary,
            ),
        )
    }

    @Test
    fun `a null authority is unknown`() {
        assertEquals(
            DocumentPathResolver.Step.Unknown,
            DocumentPathResolver.plan(
                null,
                "whatever",
                apiLevel = 36,
                primaryRoot = primary,
            ),
        )
    }
}
