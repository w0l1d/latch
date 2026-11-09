#!/usr/bin/env bash
# Deterministic fixtures for the on-device UI suite.
#
# Everything is generated here rather than committed as binaries: the suite
# must be able to rebuild its own inputs from a clean checkout, and a fixture
# whose bytes change silently would make a passing run meaningless.
#
# Sizes are chosen around the v1 chunk size (65536) so the round-trip tests
# straddle a real secretstream chunk boundary instead of only exercising the
# easy path.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

build_fixtures() {
  local out="$1"
  rm -rf "$out"
  mkdir -p "$out/bulk/nested/deeper" "$out/empty-folder"

  printf 'The quick brown fox jumps over the lazy dog.\n' > "$out/alpha.txt"

  {
    printf '# Field notes\n\n'
    printf 'Latch is offline and stateless. Forgotten passphrase means the\n'
    printf 'file is gone; there is no server to ask and no reset link.\n\n'
    local i
    for i in $(seq 1 20); do
      printf -- '- note %02d: the .latch container is a v1 header plus a secretstream\n' "$i"
    done
  } > "$out/beta.md"

  {
    printf 'id,name,amount,currency\n'
    local i
    for i in $(seq 1 400); do
      printf '%d,account-%03d,%d.%02d,EUR\n' "$i" "$i" "$((i * 7 % 900 + 100))" "$((i % 100))"
    done
  } > "$out/gamma.csv"

  printf 'name with spaces and unicode: café ☐ 日本語\n' > "$out/unicode café ☐.txt"

  # Scenarios whose output does not stay in the fixture folder each own a file.
  # The `dl-` prefix is reserved for the suite: it is what lets cleanup delete
  # from public Downloads without guessing, and what makes "exactly one
  # container" assertions exact when flows share a device run.
  printf 'Downloads fallback probe.\n'          > "$out/dl-fallback.txt"
  printf 'Downloads after a declined rationale\n' > "$out/dl-downloads.txt"
  printf 'cancelled before any output\n'        > "$out/dl-cancel.txt"
  printf 'remembered destination, first batch\n'  > "$out/dl-remember-a.txt"
  printf 'remembered destination, second batch\n' > "$out/dl-remember-b.txt"

  # 14/10 assert that nothing at all was written, so their source is dedicated:
  # no other flow can leave a container beside it and blur the result.
  printf 'nothing should ever be written from this\n' > "$out/cancel-probe.txt"

  # 12 backs out of the permission picker and recovers via "Choose folder".
  printf 'granted on the second attempt\n' > "$out/choose-probe.txt"

  # 15 spans two folders: the fixture root and `bulk/`, which the grant on the
  # root already covers as an ancestor.
  printf 'top-level member of a two-folder batch\n' > "$out/two-a.txt"

  # 17 sends its output to a folder chosen on the options screen, so the
  # container must end up in `bulk/` and *not* beside this file.
  printf 'saved somewhere the user picked in advance\n' > "$out/explicit-dst.txt"

  : > "$out/empty.bin"

  # Filled with `dd | tr` rather than `yes | head -c`: `yes` dies of SIGPIPE
  # when `head` closes the pipe, and under `pipefail` that fails the script for
  # a reason that has nothing to do with the fixture.
  dd if=/dev/zero bs=65536 count=1 2>/dev/null | tr '\0' 'A' > "$out/exactly-64k.bin"
  dd if=/dev/zero bs=65537 count=1 2>/dev/null | tr '\0' 'B' > "$out/over-64k.bin"
  dd if=/dev/zero bs=1048576 count=2 2>/dev/null | tr '\0' 'C' > "$out/large-2mb.bin"

  # Bulk folder: three levels deep, mixed sizes, plus a file that must collide
  # with a same-named file in another subfolder (mirrored placement must not
  # overwrite one with the other).
  # Flow 05 locks a whole folder, so it needs a folder of its own: a bulk run
  # over the fixture root would leave a container beside every other flow's
  # source and change what their before/after assertions see. `sub/` exists so
  # the default (non-recursive) scan has a file it must *leave out* — the
  # difference between "3 files" and "4 files" is the toggle's real behaviour.
  mkdir -p "$out/bulk-dir/sub"
  printf 'first file in the folder run\n'  > "$out/bulk-dir/one.txt"
  printf 'second file in the folder run\n' > "$out/bulk-dir/two.txt"
  dd if=/dev/zero bs=65537 count=1 2>/dev/null | tr '\0' 'E' > "$out/bulk-dir/three.bin"
  printf 'only reachable with subfolders on\n' > "$out/bulk-dir/sub/four.txt"

  # Flow 18 is the folder *round trip*: lock a folder deleting the originals,
  # then unlock the same folder and get the plaintext back byte for byte. Its
  # folder is separate from every other bulk fixture because the flow ends with
  # containers sitting next to restored plaintext — exactly the state another
  # flow's "exactly one new file" assertion would choke on.
  #
  # `nested/d3.txt` is never touched by either batch: the default scan is
  # non-recursive in both directions, so this file is the witness that neither
  # the lock nor the unlock descended into it.
  mkdir -p "$out/bulk-dec/nested"
  printf 'first file of the folder round trip\n'  > "$out/bulk-dec/d1.txt"
  printf 'second file of the folder round trip\n' > "$out/bulk-dec/d2.txt"
  printf 'must never be locked by a default scan\n' > "$out/bulk-dec/nested/d3.txt"

  # Flow 20 chooses ${REPICK_A}, then changes its mind and chooses ${REPICK_B}.
  # The counts differ on purpose (2 vs 4): "the summary now says 4 files" is
  # then evidence that the scan was *replaced*, not merely re-rendered — and
  # the host assertion can say which folder actually received the containers.
  mkdir -p "$out/repick-a" "$out/repick-b"
  printf 'first file of the folder that gets replaced\n'  > "$out/repick-a/a1.txt"
  printf 'second file of the folder that gets replaced\n' > "$out/repick-a/a2.txt"
  printf 'first file of the folder that replaces it\n'    > "$out/repick-b/b1.txt"
  printf 'second file of the folder that replaces it\n'   > "$out/repick-b/b2.txt"
  printf 'third file of the folder that replaces it\n'    > "$out/repick-b/b3.txt"
  printf 'fourth file of the folder that replaces it\n'   > "$out/repick-b/b4.txt"

  # Flow 21 repeats the repick question on the decrypt side. Its folders are
  # separate from 20's because the flow leaves *containers* in one and
  # container-plus-plaintext in the other, and its own counts (2 vs 3) keep the
  # "the scan was replaced" assertion unambiguous in that mode too.
  mkdir -p "$out/dec-repick-a" "$out/dec-repick-b"
  printf 'first locked file of the folder that gets replaced\n'  > "$out/dec-repick-a/x1.txt"
  printf 'second locked file of the folder that gets replaced\n' > "$out/dec-repick-a/x2.txt"
  printf 'first locked file of the folder that replaces it\n'    > "$out/dec-repick-b/y1.txt"
  printf 'second locked file of the folder that replaces it\n'   > "$out/dec-repick-b/y2.txt"
  printf 'third locked file of the folder that replaces it\n'    > "$out/dec-repick-b/y3.txt"

  printf 'root level\n'                > "$out/bulk/root.txt"
  printf 'nested one\n'                > "$out/bulk/nested/one.txt"
  printf 'deeper payload\n'            > "$out/bulk/nested/deeper/two.txt"
  printf 'collision in nested\n'       > "$out/bulk/nested/one.dat"
  printf 'collision in deeper\n'       > "$out/bulk/nested/deeper/one.txt"
  dd if=/dev/zero bs=200000 count=1 2>/dev/null | tr '\0' 'D' > "$out/bulk/nested/deeper/filler.bin"
}

# Push fixtures into a dedicated public folder and make them visible to
# DocumentsUI. adb-created rows land with is_pending=1 in MediaStore, and
# DocumentsUI's Downloads root reads MediaStore, so an un-cleared file is
# simply absent from the picker.
push_fixtures() {
  local out="$1"
  # Refuse to wipe anything that is not the dedicated fixture folder — this
  # runs `rm -rf` against a path on the user's phone.
  case "$DEV_DIR" in
    */"$FIXTURE_NAME") ;;
    *) echo "REFUSING: DEV_DIR '$DEV_DIR' is not a '$FIXTURE_NAME' folder" >&2; return 1 ;;
  esac

  adb shell rm -rf "$DEV_DIR"
  adb shell mkdir -p "$DEV_DIR"
  adb push "$out/." "$DEV_DIR/" >/dev/null 2>&1 || {
    echo "FAIL: could not push fixtures to $DEV_DIR" >&2
    return 1
  }
  # Directories pushed by adb can arrive as files if a name collides; verify
  # the shape we depend on rather than assuming the push worked.
  if ! adb shell "[ -d '$DEV_DIR/bulk/nested/deeper' ]"; then
    echo "FAIL: bulk/nested/deeper did not arrive as a directory" >&2
    return 1
  fi
  clear_pending
  adb shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
    -d "file://$DEV_DIR" >/dev/null 2>&1
}

# adb push writes real bytes but MediaStore's index row stays is_pending=1,
# which hides the file from both the picker and any `content query`. Clearing
# the flag is what makes an adb-staged fixture behave like a downloaded one.
clear_pending() {
  adb shell content update --uri content://media/external/file \
    --bind is_pending:i:0 \
    --where "_data LIKE '${DEV_DIR}/%'" >/dev/null 2>&1
}

# Remove outputs a previous run produced, so a passing assertion can never be
# satisfied by a stale container from an earlier run.
clean_outputs() {
  adb shell "find '$DEV_DIR' -maxdepth 3 -name '*.latch' -delete" >/dev/null 2>&1
  adb shell "find '$DEV_DIR' -maxdepth 3 -name '*.tmp' -delete" >/dev/null 2>&1
  # The Downloads-destination scenarios write into public Downloads, which the
  # fixture sweep cannot see. Only names this suite owns are touched: the `dl-`
  # prefix is reserved for these flows, so a stale container can never make a
  # "was it written?" assertion pass on its own — and a stray delete here can
  # never reach a file the fixture generator did not create.
  adb shell "find '$DOWNLOADS_DIR' -maxdepth 1 -name 'dl-*.latch' -delete" >/dev/null 2>&1
  adb shell "find '$DOWNLOADS_DIR' -maxdepth 1 -name 'dl-*.tmp' -delete" >/dev/null 2>&1
}

# A single pristine scratch copy of one file, used by the delete-originals
# scenarios so they never consume the shared fixture.
refresh_scratch() {
  local name="$1"
  adb shell rm -f "'$DEV_DIR/$name'" "'$DEV_DIR/$name.latch'" >/dev/null 2>&1
  adb shell "cp '$DEV_DIR/$name.src' '$DEV_DIR/$name'" >/dev/null 2>&1
  clear_pending
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  req="${1:-/tmp/latch-e2e-fixtures}"
  build_fixtures "$req" && echo "fixtures: $req"
fi
