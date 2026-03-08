# Endpoint Rotation Automation

A small set of fail-safe scripts to keep a private server↔client setup operational:
- monitor the current endpoint health
- select a replacement from scan results
- apply configuration changes via a local management API with backup / verify / rollback
- optionally notify via Telegram
- generate router-side sync artifacts (OpenWrt)

## What is included
- `install.sh`: interactive installer (creates env file, installs systemd units, generates router artifacts under `out/`).
- `autorotate/bin/*.sh`: main entrypoints (`watchdog.sh`, `rotate.sh`).
- `autorotate/modules/*`: helper modules (TLS verification, scan+pick, API update, Telegram notify).
- `autorotate/systemd/*`: example systemd unit/timer files.
- `autorotate/openwrt/*`: router-side sync script + config example.
- `reality-realtlscanner-pipeline.sh`: optional scanner pipeline script used by `scan_pick.sh`.

## Security notes
- **Do not commit secrets**. Put runtime secrets into an env file (example template is committed).
- Generated/runtime directories (scanner checkout/build artifacts, temp outputs, `out/`) are ignored by `.gitignore`.

## Quick start (Linux + systemd)
1) Run installer:
```bash
sudo bash install.sh
```

2) Dry-run (no changes applied):
```bash
set -a; . /etc/reality-autorotate.env; set +a
"$PROJECT_ROOT/autorotate/bin/rotate.sh" --trigger manual --dry-run
```

3) Check timer status:
```bash
systemctl status reality-autorotate-watchdog.timer --no-pager
```

## Configuration
- Production-style env file path: `/etc/reality-autorotate.env` (mode 600).
- Template: `autorotate/.env.example`.

## Router-side sync (OpenWrt)
After running `install.sh`, copy artifacts from:
- `out/openwrt/`

onto the router and follow the instructions in the generated `INSTALL_OPENWRT.txt`.

## Legal / policy
This repository is intended for managing **your own** private infrastructure. You are responsible for complying with applicable laws, regulations, and your hosting/provider policies.
