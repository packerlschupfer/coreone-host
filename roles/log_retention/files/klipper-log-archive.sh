#!/usr/bin/env bash
# Archive klippy's rotated logs before klippy deletes them.
#
# WHY THIS EXISTS: klippy does its OWN rotation -- klippy/queuelogger.py opens a
# TimedRotatingFileHandler with `when='midnight', backupCount=5`, hardcoded in Klipper
# source. So klippy.log covers ~5 days and then the oldest is unlinked, and that is not
# configurable from printer.cfg, the service unit, or a command-line flag.
#
# On 2026-09-12 that cost us a diagnosis: three `klippy_shutdown` events from July were
# permanently unclassifiable because the logs holding the fault line had aged out, while
# the ONE event we could still see had its logs only by luck of timing. An intermittent
# fault is diagnosed from the occurrence you still have evidence for.
#
# WHY ARCHIVE RATHER THAN RAISE backupCount: raising it means patching Klipper source in
# the firmware fork -- a vendored file that a fork update would revert, and a dirty tree
# that Moonraker's update_manager flags. Copying the rotated files out is additive,
# version-independent, and cannot affect klippy: we only ever read files klippy has
# ALREADY rotated (klippy.log.YYYY-MM-DD) and never touch the live klippy.log it holds open.
set -euo pipefail

LOGDIR="${1:?usage: $0 <printer_data/logs dir> <retain days>}"
RETAIN="${2:?usage: $0 <printer_data/logs dir> <retain days>}"
ARCHIVE="$LOGDIR/archive"

mkdir -p "$ARCHIVE"

# Only ROTATED logs. The bare `klippy.log` / `moonraker.log` are open for append by a
# running daemon; copying a torn mid-write snapshot would archive a corrupt tail.
shopt -s nullglob
for f in "$LOGDIR"/klippy.log.* "$LOGDIR"/moonraker.log.*; do
    base="$(basename "$f")"
    # Skip what we already hold. The -nt test keeps re-runs cheap but still picks up a
    # file that was rotated again under the same name on the same day.
    # Written as an `if` on purpose: as an `A && B && continue` one-liner this relies on
    # `set -e` ignoring a false test in a non-final position of an AND-OR list. That is
    # correct per POSIX, but it is a rule people edit straight through, and getting it
    # wrong makes the script exit silently on its FIRST file -- archiving nothing, while
    # still exiting 0 to systemd. Too quiet a failure for a safety net.
    if [ -e "$ARCHIVE/$base.gz" ] && [ ! "$f" -nt "$ARCHIVE/$base.gz" ]; then
        continue
    fi
    gzip -c "$f" > "$ARCHIVE/$base.gz.tmp" && mv "$ARCHIVE/$base.gz.tmp" "$ARCHIVE/$base.gz"
done

# Age out the archive itself, or this grows without bound on a host with a small SD card.
find "$ARCHIVE" -maxdepth 1 -name '*.log.*.gz' -mtime "+$RETAIN" -delete
