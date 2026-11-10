package com.latch.latch

/**
 * Splits the relative folder path a bulk output is mirrored into
 * (`"Work/2026/Q3"`) into the folder names to find-or-create, in order.
 *
 * Pure Kotlin so the rules are JVM-testable. `.` and `..` are rejected rather
 * than skipped: a segment that climbs out of the granted tree must never reach
 * `DocumentsContract`, and silently dropping it would write the file somewhere
 * the caller did not ask for.
 */
object SubPathSegments {
    fun split(subPath: String): List<String> {
        if (subPath.isEmpty()) return emptyList()
        val parts = subPath.split('/').filter { it.isNotEmpty() }
        require(parts.none { it == "." || it == ".." }) {
            "subPath must not contain '.' or '..' segments: $subPath"
        }
        require(parts.none { it.contains('\u0000') }) { "subPath contains a NUL byte" }
        return parts
    }
}
