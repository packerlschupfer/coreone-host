# OrcaSlicer machine profile — Prusa Core One (Klipper)

`Prusa_Core_One_Klipper.json` — an OrcaSlicer **machine** preset for the Core One
running this Klipper port.

Import into OrcaSlicer: **File → Import → Import Configs…** → pick this `.json`.
Then add the network printer: **Physical Printer → Host Type "Klipper (Moonraker)"**,
hostname `klipper.local` (or the Pi's IP), port 80 (or 7125), **no API key** (your
LAN subnet is trusted in `moonraker.conf` — see `lan_subnet` in `group_vars/all.yml`).

> ✅ **Print-proven.** A single-wall test (PLA, smooth PEI) runs end-to-end:
> `PRINT_START` (probe-temp → G28 loadcell Z → full `BED_MESH_CALIBRATE` → ramp →
> skirt) → clean first layer → full part → `PRINT_END` (heaters off, park), with
> the contract/guard holding and the filament sensor active throughout.

## Contract — verified against the printer.cfg macros

The start/end gcode in this profile is verified against the macros, not inferred:

- **`PRINT_START` is the entry point; param names `BED` / `EXTRUDER` / `CHAMBER`
  are final.** This profile emits
  `PRINT_START EXTRUDER=… BED=… CHAMBER=[chamber_temperature]`.
- **`CHAMBER=` drives chamber venting** (added 2026-06-13). The Core One chamber
  is a native `[temperature_fan ext_chamber]` cooling regulator. `CHAMBER=<C>` is
  a **vent ceiling** (keep at/below), NOT heat-up-to: PLA → set the filament's
  Chamber temp to **~20** (vents); PETG ~35; ABS/ASA ~55 (fan stays off, chamber
  warm — pass `SOAK` for a pre-warm). `0`/omitted = off. Per-filament value lives
  in OrcaSlicer **Filament → Temperature → Chamber**; this profile passes it via
  `[chamber_temperature]`. ⚠️ verify in exported gcode that `CHAMBER=` resolves to
  the real number (e.g. `CHAMBER=20`), not `0` or a literal.
- **PRINT_START does everything** — probe-temp set, heat+wait bed, optional SOAK,
  nozzle to PROBE_TEMP, G28 (XY + loadcell Z), `BED_MESH_CALIBRATE`, ramp hotend,
  **prime line**, end at Z2. So the slicer Start G-code stays MINIMAL — the single
  `PRINT_START` call. **Do NOT add** heating / homing / mesh / prime / M104 / M140
  / G28 / G29 in the slicer, or you double-heat, double-home, or double-prime.
- **`PRINT_END` is complete** (M400 → heaters off → fan off → retract → Z-lift →
  park X5 Y200 → M84). Append nothing after it.
- **Z offset is baked in** (`[load_cell_probe] z_offset = -0.054` via SAVE_CONFIG).
  The slicer needs **no Z-offset / babystep**. (Operator can still live-tune with
  `SET_GCODE_OFFSET`, persist via `Z_OFFSET_SAVE`.)

### Silent-default hazard — GUARDED ✅ (but still emit the keys exactly)

Every PRINT_START param is `params.X|default(...)`, so a **missing or misspelled**
key would silently fall back to `BED=60, EXTRUDER=215, …`. This profile emits
exactly `EXTRUDER=` / `BED=` — don't edit those keys.

> **Hard-fail guard is LIVE** in printer.cfg. PRINT_START aborts cleanly via `action_raise_error`
> **before any M104/M140** if:
> - `EXTRUDER` or `BED` is absent/misspelled → *"missing EXTRUDER/BED — slicer
>   Start G-code must pass both (silent-default guard)"*
> - `EXTRUDER` outside **150–300 °C**, or `BED` outside **40–120 °C** (bands sit
>   just inside heater `max_temp` 305 / 120).
>
> So a name typo or garbage temp now *aborts with heaters at 0*, it doesn't
> mis-heat. `PROBE_TEMP`/`SOAK`/`ADAPTIVE` stay optional defaults. A valid
> `EXTRUDER=215 BED=60` passes straight through. Verified: all three abort cases
> fire, klippy stays `ready` — clean abort, not a crash.

**One-line self-check after import:** slice a 1-layer test, open the `.gcode`, and
confirm the first line reads e.g. `PRINT_START EXTRUDER=215 BED=60` with the
*actual* numbers from your filament profile — not the macro defaults.

## Known gotcha — bed-type placeholder context (the "textured plate trap")

`machine_start_gcode` emits `BED=[bed_temperature_initial_layer_single]`. That
placeholder is **bed-type-context-dependent**: it resolves to whichever plate is
selected (`curr_bed_type`). With no explicit bed type it can fall back to
**"Cool Plate" = 35 °C** → `BED=35`.

- **Backstop:** 35 < the PRINT_START guard's 40 °C floor, so this fails *safe* —
  PRINT_START aborts (`BED=35 out of range 40-120C`), it does not print cold.
- **Example:** a "First Layer Test" process preset that carries
  `curr_bed_type = Textured PEI Plate` (matching the installed sheet) with the
  filament's `textured_plate_temp[_initial_layer]` set to 60 resolves to `BED=60`
  correctly.
- **Long-term convention is undecided** (slicer-side). Options: keep `_single`
  (plate-following, idiomatic; rely on presets + the guard) vs. switch to
  `[hot_plate_temp_initial_layer]` / `[textured_plate_temp_initial_layer]`
  (bed-type-independent, but wrong if the sheet changes). Whatever is chosen,
  update this `machine_start_gcode` to match.

## Adaptive mesh & chamber soak (why the defaults are what they are)

- **`ADAPTIVE` stays 0** (omitted) in this profile. PRINT_START runs a **fresh full
  `BED_MESH_CALIBRATE` every print** (it does not load the saved mesh). `ADAPTIVE=1`
  probes only the labelled print area but **requires OrcaSlicer "Label Objects" /
  EXCLUDE_OBJECT output** — enable + verify that first, then add `ADAPTIVE=1` to the
  start gcode.
- **`SOAK` stays 0** in this profile (PRINT_START's SOAK is just a passive `G4`
  dwell). For ABS/ASA/PC, do an **active chamber soak as a separate operator step
  before slicing-print**, not in the slicer:
  `PREHEAT BED=<t> CHAMBER=40-45 SOAK=10-15 [EXTRUDER=0]` (heats bed, parks centre,
  runs the H503 circulation fan, waits the chamber to a floor). The Core One has
  **no chamber heater** (passive — bed + circulation), so `CHAMBER` is *not* a
  PRINT_START param.

## What's authoritative vs. sensible-default

| Field(s) | Source | Authoritative? |
|---|---|---|
| `gcode_flavor: klipper`, `printer_structure: corexy` | machine is Klipper/CoreXY | ✅ |
| `printable_area` 250×220, `printable_height` 270 | Prusa Core One spec (verified) | ✅ — verify if yours is a **Core One L** (bigger bed) |
| `machine_max_speed_x/y` 350, `_z` 30 | `boards/xbuddy.cfg` | ✅ source of truth |
| `machine_max_acceleration_extruding/travel` **10000** (= Klipper `max_accel` ceiling), `_x/y` 7000, `_z` 1000 | `boards/xbuddy.cfg` + phase-step envelope | ✅ motion-planner CEILING — actual print accel is per-feature M204 (see notes) |
| `machine_start_gcode` / `machine_end_gcode` | `printer.cfg` PRINT_START / PRINT_END | ✅ **contract confirmed** (start-gcode passes `CHAMBER_MIN` when chamber>25) |
| `machine_max_speed_e` 10, `accel_e` 2500, `machine_max_jerk_x/y` 10 | phase-step-validated envelope (Nextruder + `xbuddy.cfg`) | ✅ match hw. Klipper **ignores gcode jerk** (uses host `square_corner_velocity`) — jerk here is cosmetic. |
| `retraction_*`, `z_hop` **1.0**, `retraction_minimum_travel` 0.5, layer-height min/max | brim-drag fix + sensible defaults | z_hop/min-travel are the brim-drag fix (see notes); rest tune per testing |

## Notes

- **Don't set slicer-side input shaping or pressure advance** — Klipper owns them
  host-side (`[input_shaper] ei@55.4 / mzv@43.4` + PA in printer.cfg).
- **Accel model = ceiling + per-feature.** `machine_max_acceleration_extruding/travel = 10000` is
  the motion-planner CEILING (= Klipper `max_accel` in `boards/xbuddy.cfg`); the actual print accel
  is driven **per-feature via M204** (anchors: outer 2500 / inner 3000 / infill 5000). The ceiling
  must be ≥ the highest per-feature accel or Orca clips it and ETAs lie. Above 150 mm the host
  `_ACCEL_TAPER` macro clamps X/Y down (7000→4000@200→2000@270) for tall-print ringing — the slicer
  just emits `_ACCEL_TAPER Z=[layer_z]` per layer (`before_layer_change_gcode`); below 150 mm it's a
  no-op. Validated across the full 10000 envelope (phase-stepping, 2026-07-03).
- **Brim-drag fix.** PRINT_START hands off at `X150 Y100 Z2` with a primed tip and
  `[firmware_retraction]` intentionally OFF, so the first travel must clear it: `z_hop 1.0` +
  `retraction_minimum_travel 0.5` (retract + lift over the hand-off) prevent a full-width line
  dragging from the hand-off point to the brim start.
- **Co-evolving with the FW port.** This profile now tracks the coreone-firmware port (CHAMBER_MIN,
  phase-step envelope, accel taper, brim-drag) rather than Prusa stock — expect **frequent syncs**
  from the slicer chat for a while. The staged copy here is the source of record; the live OrcaSlicer
  copy leads and gets synced back.
- Output **plain `.gcode`**, not `.bgcode` (that's a Buddy/PrusaLink thing).

## Sources

- OrcaSlicer built-in placeholder variables: https://github.com/OrcaSlicer/OrcaSlicer/wiki/Built-in-placeholders-variables
- OrcaSlicer start-gcode guide (Obico): https://www.obico.io/blog/start-g-code-in-orca-slicer-start-your-print-the-right-way/
- Prusa Core One specs (build volume 250×220×270): https://www.prusa3d.com/product/prusa-core-one/
