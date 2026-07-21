#!/usr/bin/env bash
# Auto-recover Klipper after the F427/H503 MCU re-enumerates on a separately-
# powered host. Two cases are covered:
#
#   1. Cold boot -- the printer is power-cycled while the Pi stays up. The MCU
#      vanishes and returns; klippy sits in "shutdown". A FIRMWARE_RESTART
#      reconnects it.
#   2. Mid-session re-enumeration -- the USB link re-enumerates under a running
#      klippy (e.g. the F427 USB-C is jostled). klippy goes to "shutdown" holding
#      a STALE serial handle that a FIRMWARE_RESTART canNOT re-open (it resets the
#      firmware + restarts klippy in-process but keeps the old fd). Only a full
#      `systemctl restart klipper` re-grabs the re-enumerated port.
#
# Triggered by udev when either Klipper serial re-enumerates, this waits for BOTH
# MCUs and, only if klippy is stuck (shutdown/error), tries FIRMWARE_RESTART and
# then ESCALATES to a service restart if that didn't recover. A healthy klippy
# (ready / fresh startup) is left untouched.
#
# Runs as root (systemd oneshot, no User=) so the escalation can restart klipper.
set -u
# Runs as root (systemd oneshot). Keep state OFF the sticky /tmp: with
# fs.protected_regular=2 (Debian default) even root cannot write a file it does
# not own in a world-writable sticky dir, which silently broke logging when the
# unit switched from User=pi to root. /var/log + /run are root-owned.
LOG=/var/log/klipper-mcu-recover.log
STAMP=/run/klipper-mcu-recover.last
MOON=http://localhost:7125
F427='/dev/serial/by-id/usb-Klipper_stm32f427xx_*'
H503='/dev/serial/by-id/usb-Klipper_stm32h503xx_*'

log(){ echo "$(date '+%F %T') $*" >>"$LOG" 2>/dev/null; }
state(){ curl -s "$MOON/printer/info" 2>/dev/null \
         | grep -o '"state":"[a-z]*"' | head -1 | cut -d'"' -f4; }

# Debounce: a FIRMWARE_RESTART re-enumerates the MCUs and re-fires udev, so skip
# if we already acted in the last 45s -- this is what stops a restart loop. (A
# `systemctl restart klipper` does NOT re-enumerate USB, so it cannot self-fire,
# but the debounce still guards the FIRMWARE_RESTART path.)
if [ -f "$STAMP" ] && [ $(( $(date +%s) - $(stat -c %Y "$STAMP") )) -lt 45 ]; then
    log "debounce: acted <45s ago, skip"; exit 0
fi

# Wait for BOTH MCUs (the H503 is powered off the F427 rail, comes up a bit later).
for _ in $(seq 1 20); do
    ls $F427 >/dev/null 2>&1 && ls $H503 >/dev/null 2>&1 && break
    sleep 1
done
ls $F427 >/dev/null 2>&1 && ls $H503 >/dev/null 2>&1 \
    || { log "both MCUs not present; skip"; exit 0; }

# Only act if klippy is actually stuck; poll a little, since the shutdown can lag
# the re-enumeration by a couple of seconds.
s=""
for _ in $(seq 1 12); do
    s=$(state)
    case "$s" in
        shutdown|error)
            log "klippy '$s' -> FIRMWARE_RESTART"
            touch "$STAMP"
            curl -s -X POST "$MOON/printer/firmware_restart" >/dev/null 2>&1
            # FIRMWARE_RESTART handles the cold-boot case; wait up to ~20s for ready.
            r=""
            for _ in $(seq 1 10); do
                sleep 2
                r=$(state)
                [ "$r" = ready ] && { log "recovered via FIRMWARE_RESTART"; exit 0; }
            done
            # Still not ready -> stale serial handle (mid-session re-enum). Escalate
            # to a full service restart, which re-opens the re-enumerated port.
            log "still '${r:-unknown}' after FIRMWARE_RESTART -> systemctl restart klipper"
            touch "$STAMP"
            systemctl restart klipper
            sleep 10
            log "post service-restart state: $(state)"
            exit 0 ;;
        ready)
            log "klippy ready; nothing to do"; exit 0 ;;
    esac
    sleep 2
done
log "klippy state never settled (last: '$s'); skip"
exit 0
