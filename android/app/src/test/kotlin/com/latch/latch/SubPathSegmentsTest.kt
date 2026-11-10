package com.latch.latch

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class SubPathSegmentsTest {
    @Test
    fun `empty means the tree root`() {
        assertTrue(SubPathSegments.split("").isEmpty())
    }

    @Test
    fun `nested path splits in order`() {
        assertEquals(listOf("Work", "2026", "Q3"), SubPathSegments.split("Work/2026/Q3"))
    }

    @Test
    fun `stray slashes are ignored`() {
        assertEquals(listOf("a", "b"), SubPathSegments.split("/a//b/"))
    }

    @Test
    fun `names with dots and spaces survive`() {
        assertEquals(listOf("v1.2", "my docs", "..hidden"), SubPathSegments.split("v1.2/my docs/..hidden"))
    }

    @Test
    fun `climbing segments are rejected`() {
        for (bad in listOf("..", "a/../b", "./a", "a/.")) {
            try {
                SubPathSegments.split(bad)
                fail("expected rejection of '$bad'")
            } catch (_: IllegalArgumentException) {
            }
        }
    }

    @Test
    fun `NUL is rejected`() {
        try {
            SubPathSegments.split("a/b\u0000c")
            fail("expected rejection")
        } catch (_: IllegalArgumentException) {
        }
    }
}
