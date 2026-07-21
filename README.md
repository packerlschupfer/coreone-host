# ansible_klipper — Klipper host for a Prusa Core One (custom Klipper port)

Provisions a **Raspberry Pi** as a Klipper host for a Prusa Core One running a
custom Klipper MCU port: **klippy + Moonraker + Mainsail + nginx**, all started
on boot and reproducible from one `ansible-playbook` run.

This is the **host side only** — no MCU firmware is built here. The firmware for
the xBuddy board (STM32F427) is built and flashed separately.

## What it sets up

- `klippy` (host) + `moonraker` (API on :7125) + `mainsail` (UI on :80 via nginx)
- A modern `printer_data/` layout (`config/`, `logs/`, `gcodes/`, `comms/`)
- The real `printer.cfg` + `boards/xbuddy.cfg` (the `[mcu]` serial is templated
  from `group_vars`), deployed so klippy comes up in a known state
- Passwordless SSH (your key) + `dialout` group + sudoers for re-runs

## Requirements

- A Raspberry Pi (Pi 4 or newer) running a fresh **Raspberry Pi OS Lite (64-bit)**
- Ansible on your workstation, plus the collections in `requirements.yml`:
  `ansible-galaxy collection install -r requirements.yml`
- SSH reachable to the Pi (key or first-run password)

## Quick start

1. **Flash Raspberry Pi OS Lite** to the Pi's boot device, enable SSH, create the
   `pi` user (matches `group_vars/all.yml`).
2. **Set your site-specific values** — copy the example and fill in *your* values.
   This file is **gitignored**, so your real host/IP/serial never get committed:
   ```bash
   cp host_vars/klippy.yml.example host_vars/klippy.yml
   # edit host_vars/klippy.yml: ansible_host, lan_subnet, mcu_serial
   ```
   These override the placeholders in `group_vars/all.yml` + `inventory.ini`.
   (`mcu_serial` comes from `ls /dev/serial/by-id/*` once the board enumerates.)
3. **Run it:**
   ```bash
   ansible -m ping klipper          # connectivity check
   ansible-playbook site.yml        # full provision
   ```
   First run may need `--ask-pass`; the `base` role installs your SSH key so
   later runs are passwordless.
4. **Verify:**
   ```bash
   curl http://<pi>:7125/printer/info     # Moonraker
   xdg-open http://<pi>/                   # Mainsail
   ```

## Layout

```
site.yml              orchestration: base → klipper → moonraker → printer_config → mainsail
inventory.ini         target host + user
group_vars/all.yml    all knobs: user, paths, ports, repos, lan_subnet, mcu_serial, mainsail version
roles/
  base/               apt, packages, service user, dialout group, ssh key, sudoers, printer_data dirs
  klipper/            klippy repo + venv + systemd unit (host only; numpy/scipy for input shaper)
  moonraker/          moonraker repo + venv + conf + systemd unit (:7125)
  printer_config/     real printer.cfg + boards/xbuddy.cfg ([mcu] serial templated) + h5 extension
  mainsail/           static UI download + nginx site (:80)
slicer/               OrcaSlicer machine profile for this printer + its README
```

## Notes

- **`printer.cfg` is deploy-once** (`force: false`) — klippy appends its
  `SAVE_CONFIG` block (PID, probe z-offset, bed mesh, input shaper), so the
  playbook never clobbers it after the first deploy. `boards/xbuddy.cfg` is
  Ansible-owned and force-updated each run (the `[mcu]` serial comes from
  `mcu_serial`).
- **Idempotent** — safe to re-run. Repos use `update: false`; bump `*_branch` in
  `group_vars/all.yml` deliberately to update Klipper/Moonraker.
- **OrcaSlicer** — import `slicer/Prusa_Core_One_Klipper.json` and connect via
  the Moonraker host type. See `slicer/README.md` for the `PRINT_START` contract.
- **LAN-only by design** — Moonraker trusts `lan_subnet`; don't expose it to the
  public internet.

## Per-machine calibration (run once on your printer)

This config ships **uncalibrated** on purpose — the machine-specific tuning is left out
so it's a safe starting point for *any* Core One, not a copy of one specific machine.
Klippy regenerates the `SAVE_CONFIG` block (PID, probe z-offset, bed mesh, input shaper)
on first use; the rest you run yourself:

- **Hotend + bed PID** — `PID_CALIBRATE HEATER=extruder TARGET=…` / `HEATER=heater_bed`
- **Input shaper** — `SHAPER_CALIBRATE` (needs an accelerometer; otherwise leave defaults)
- **Probe Z-offset** — dial in the first layer live, then `Z_OFFSET_SAVE`
- **Bed mesh** — `BED_MESH_CALIBRATE` (PRINT_START also runs a fresh one each print)
- **Sensorless-homing StallGuard** — `CALIBRATE_HOMING_SGT AXIS=X|Y`, set `driver_SGT`
- **Phase-snap homing ref** — `MSCNT_SNAP_CALIBRATE AXIS=X|Y` → `[mscnt_home] calibrated_phase`

### Phase-stepping — default ON (like Prusa)

Phase-stepping is **on by default**: no accelerometer kit required, matching how Prusa
ships the Core One. It runs out-of-box with **no cogging correction** (identity) — exactly
Prusa's uncalibrated default; base phase-stepping is the validated benefit.

**Cogging correction is per-machine and optional.** The `[phase_exec stepper_x/y]` harmonic
values must be measured on *your* motors (cogging calibration; see `extras/phase_cogging.py`)
— do **not** copy another machine's, wrong values make motion worse. To run a given print
without phase-stepping, pass `PHASE_STEP=0` (or `SAFE_PRINT_MODE VALUE=1`).

## Hardware notes

### USB backpower — boot-order gotcha (root is on USB)

**Symptom:** if the **printer is powered on before the Pi**, the Pi hangs early in
boot — **no ethernet, Mainsail never comes up**. Power the printer *off* and the Pi
boots normally; power it back *on* afterwards and everything connects fine.

**Cause:** root is on the USB SSD (`root=/dev/sda2`, kernel cmdline `rootwait`). The
xBuddy (STM32F427) and the H5 (STM32H503) boards are **self-powered by the printer
PSU**; their USB-device ports backfeed ~5 V onto VBUS into the Pi. On a *cold* start
that backfeed prevents a clean USB/PMIC power-on reset → the VL805 USB controller
comes up wedged → `rootwait` never finds the USB root device → boot stalls **before
networking**. It is **not** an undervoltage (`vcgencmd get_throttled` = `0x0`) and
**not** fixable in software — the stall happens before the kernel owns USB. Powering
the printer off removes the backfeed so the Pi resets cleanly; the MCUs then hot-plug
normally onto the already-running USB stack.

**Fix:** put a **VBUS-blocked (data-only) inline adapter on the two Pi↔MCU links**.
Use a *power-blocking* adapter — e.g. PortaPow **Power Blocker** (cuts the 5 V pins,
passes data). ⚠️ NOT the common "USB data blocker", which does the opposite (passes
power, cuts data). The MCUs are self-powered, so they don't need 5 V from the Pi —
D+/D−/GND suffice. Leave the **SSD cable a normal full cable** (the Pi powers the
SSD). With VBUS cut on the MCU links, boot order no longer matters.

**Confirm test (no parts):** with the printer ON, unplug *both* MCU USB cables from
the Pi, then cold-boot — if it boots fine (ethernet up) the backpower diagnosis is
confirmed; hot-plug the MCUs after it's up.
