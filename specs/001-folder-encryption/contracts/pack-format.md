# Contract: Folder Pack Format — tar PAX subset (normative)

Used when the payload preamble declares `kind = packedFolder`,
`packFormat = 0x01`.

## 1. Base format

POSIX **USTAR** records with **PAX extended headers** (POSIX.1-2001) used only
where a USTAR field cannot hold the value:

- paths longer than 100 bytes → PAX `path`
- link targets longer than 100 bytes → PAX `linkpath`
- any name whose UTF-8 encoding does not fit the USTAR fields

PAX is chosen over GNU long-name extensions because it is the standard, encodes
names as UTF-8 by specification (needed for byte-identical names, FR-018), and is
read and written by Python's stdlib `tarfile` with `format=tarfile.PAX_FORMAT` —
which is what makes an independent oracle possible (Principle V).

## 2. Permitted type flags

| Flag | Type | Notes |
|---|---|---|
| `0` | regular file | |
| `5` | directory | Emitted explicitly, including empty directories. |
| `2` | symbolic link | `linkname` recorded verbatim, never followed. |

**Every other type flag MUST be rejected on read** — hard links (`1`), character
and block devices (`3`, `4`), FIFOs (`6`), contiguous files (`7`), GNU sparse and
dump extensions. On write they never occur: such objects are reported as
unpreservable during enumeration (FR-004) and are not packed.

## 3. Field rules

| Field | Written as | Why |
|---|---|---|
| `name` | Relative path from the selection root, `/`-separated, UTF-8 | FR-016, FR-018 |
| `mode` | `0o755` for directories and executables, `0o644` otherwise | The executable bit is in scope; the rest of the permission set is not (FR-020a) |
| `modified` | The entry's modification time | FR-020a |
| `uid` / `gid` | `0` | Out of scope, and would leak the encrypting user's identity into the container |
| `userName` / `groupName` | empty | Same |
| `size` | Exact byte length for files; `0` for directories and links | See §5 |

## 4. Determinism

FR-020 requires that restoring the same capture twice yields identical trees, and
the round-trip tests require that packing the same tree twice yields identical
bytes. Therefore:

- entries are emitted in **byte-wise sorted order** of the UTF-8 relative path;
- a directory is emitted before anything beneath it;
- no field carries ambient state (no current time, no process uid, no locale).

## 5. Size honesty

A tar header declares a file's size **before** its content. If the file changes
between `stat` and read, the archive is silently corrupt.

- **Writer:** MUST compare bytes actually read against the declared size and
  **abort the whole operation**, naming the entry, on any mismatch — the same
  abort path as an unreadable entry (FR-031).
- **Reader:** MUST enforce the declared size and reject a short or long record.

## 6. Read-side rejections (the `SafeUnpacker` chokepoint)

A container is attacker-supplied data by the time it is restored, and successful
authentication proves only that it was produced with the passphrase — **not** that
its contents are benign (FR-020d). Every entry MUST pass these checks before any
filesystem call, and a failure aborts the restore with **zero bytes written
outside the destination root**:

1. absolute path, or a path with a root or drive prefix → reject
2. any path segment equal to `..` → reject
3. normalised path that does not start with the destination root → reject
4. symlink target that is absolute, or that escapes the destination root once
   joined to the link's own directory → reject
5. type flag outside §2 → reject
6. declared size disagrees with bytes read → reject
7. duplicate relative path within one archive → reject
8. empty path, or a path that normalises to `.` → reject

## 7. Compression

None. `compression = 0x00` in the preamble. FR-020f permits compression but notes
it makes container size correlate with content compressibility — a disclosure the
product does not currently make and that no success criterion asks for.
