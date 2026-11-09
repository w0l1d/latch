#!/usr/bin/env python3
"""Print the label DocumentsUI gives the internal-storage volume.

    root_label.py <uiautomator-dump.xml>

Why this exists: `subflows/open_fixtures.yaml` has to tap the internal-storage
volume in the picker's drawer, and that row has no stable name. AOSP's string
is "Internal storage", but OEMs name the volume after the phone, and this
device is a Samsung that calls an SM-A546B "Walid's A54 backup". Selecting by
the AOSP string fails on hardware that renamed it, with an error that reads
like a broken picker.

The name cannot be read over adb either — `content query` on the documents
provider is refused for uid 2000, and DocumentsUI is not exported, so `am
start` cannot reach it. It is only visible on screen, which is why run.sh
opens the picker and dumps the view tree for this script to read.

Exit status: 0 with the label on stdout, 1 (reason on stderr) when the dump
does not contain an answer.

The distinction between "the drawer is open on the volume list" and "the
drawer is open on a document picker" matters, so it is checked rather than
assumed. Both modes render a `roots_list`; the document picker's first row is
"Recent", a shortcut whose text would be tapped as if it were a volume and
send the flow into the wrong provider. `SHORTCUT_ROWS` is that detection.

Read the dump with `python3 -I` (as the callers do): it is device output and
should not be able to influence which modules get imported.

The dump is device output, so it is parsed defensively without pulling in a
dependency: `defusedxml` is not a given on a machine that only needs adb and
Maestro, and a DTD is the one construct an `uiautomator` dump never legitimately
contains. Refusing it removes entity-expansion bombs at the door; stdlib
ElementTree already refuses external entities and never fetches a DTD.
"""

import sys
import xml.etree.ElementTree as ET

# The document picker's root list starts at "Recent" and only later reaches a
# volume. Any of these as the first row means detection ran in the wrong picker
# mode, not that the volume is called "Downloads".
SHORTCUT_ROWS = {
    "Recent",
    "Images",
    "Videos",
    "Audio",
    "Documents",
    "Downloads",
    "Bug reports",
}

TITLE_ID = "android:id/title"


def first_volume_label(path):
    """Return the first row of the drawer's volume list, or None."""
    with open(path, "rb") as handle:
        raw = handle.read()

    # See the module docstring: a dump has no DTD, so one is either corruption
    # or an attempt to make the parser expand something.
    if b"<!DOCTYPE" in raw or b"<!ENTITY" in raw:
        raise ET.ParseError("dump declares a DTD or entity; refusing to parse it")

    root = ET.fromstring(raw)

    for node in root.iter():
        if not node.get("resource-id", "").endswith(":id/roots_list"):
            continue
        for row in node.iter():
            if row.get("resource-id") != TITLE_ID:
                continue
            text = (row.get("text") or "").strip()
            if not text:
                continue
            return text
        # An empty roots_list: no titled row, so no answer.
        return None

    return None


def main(argv):
    if len(argv) != 2:
        print("usage: root_label.py <uiautomator-dump.xml>", file=sys.stderr)
        return 2

    try:
        label = first_volume_label(argv[1])
    except ET.ParseError as exc:
        print("not a uiautomator dump: %s" % exc, file=sys.stderr)
        return 1
    except OSError as exc:
        print("cannot read %s: %s" % (argv[1], exc.strerror or exc), file=sys.stderr)
        return 1

    if label is None:
        print("no volume list in the dump (drawer not open?)", file=sys.stderr)
        return 1

    if label in SHORTCUT_ROWS:
        print(
            "first drawer row is %r — the drawer is a document picker, not a "
            "folder picker" % label,
            file=sys.stderr,
        )
        return 1

    print(label)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
