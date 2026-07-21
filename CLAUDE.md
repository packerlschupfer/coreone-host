# CLAUDE.md — working rules for this repo

Ansible that provisions a Raspberry Pi as the **Klipper host** for a **Prusa Core One+**
running the [coreone-firmware](https://github.com/packerlschupfer/coreone-firmware) open
Klipper port: klippy + Moonraker + Mainsail + nginx, `printer.cfg` + macros + board config,
MCU auto-recovery, and host-timing hardening.

See **[README.md](README.md)** for what it sets up, the role layout, and the quick start.
This is the host-side companion to the firmware repo above.

## Hard rules

- **Secrets live ONLY in `host_vars/klippy.yml`, which is gitignored** (`host_vars/*.yml`).
  Real host/IP/serial (hostname, LAN subnet, MCU `/dev/serial/by-id` path) go there and
  **must never be committed**. The tracked tree is placeholder-only; the template is
  `host_vars/klippy.yml.example` — copy it, fill in your values, run.
  - Enforced by two guards: the `.gitignore` above, and a `.git/hooks/pre-commit` secret
    gate that blocks any staged file carrying a real serial / LAN subnet / hostname.
  - **This repo is PUBLIC.** Never put a real hostname, a real `192.168.x` subnet, or an
    MCU serial in a commit, comment, or example.

- **The shipped config is a generic starter, not one machine's copy.** `printer.cfg` omits
  per-machine tuning (no `SAVE_CONFIG` block, no `[phase_exec]` cogging harmonics) — those
  are calibrated on each printer. Don't paste one machine's calibration into the tracked
  config. See the "Per-machine calibration" section in the README.

- **Don't commit AI-tooling artifacts.** `.claude/`, `.cursor/`, `.aider*`, `CLAUDE.local.md`
  are ignored (machine-wide via `~/.config/git/ignore`, and this repo's `.git/info/exclude`).
  Only this curated, secret-free `CLAUDE.md` is tracked.

- **Match the existing style** — Ansible role/task conventions, comment density, and the
  `force: false` (deploy-once) vs templated (`*.j2`) split already used in the roles.
