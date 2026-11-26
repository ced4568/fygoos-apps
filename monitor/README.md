# Fygo Monitor

Prometheus + Grafana monitoring packaged as a Fygo OS app. Install it, open it from the desktop, and a NAS dashboard is already there: CPU, memory, volumes, disk I/O, ZFS ARC, network, and optionally Docker containers.

## What's in the stack

| Service | Role | Exposed |
|---|---|---|
| Grafana | UI, opened from the Fygo desktop | port 3300 |
| Prometheus | Stores metrics (retention set in the wizard) | internal only |
| node-exporter | Host metrics: CPU, memory, disks, ZFS, network | internal only |
| cAdvisor | Container metrics. Sleeps until switched on (reads the Docker socket, see PERMISSIONS.md) | internal only |

## Project layout

```
manifest                      app metadata, port 3300
app/docker/docker-compose.yaml
app/docker/prometheus/        scrape config
app/docker/grafana/           provisioned datasource and dashboard
app/ui/config                 desktop entry (iframe to Grafana)
cmd/common                    saves settings and writes the files the containers read, shared by lifecycle scripts
cmd/*                         lifecycle scripts
config/resource               declares the Compose project
wizard/install|config|uninstall
```

Shared tooling lives at the repo root: `scripts/validate.sh` (local pre-flight checks) and `.github/workflows/build.yml` (CI: validate, build .fpk, attach to releases).

## How settings flow

1. The install wizard collects the Grafana password, retention and the container metrics toggle.
2. `install_callback` validates them and saves `$TRIM_PKGETC/settings.env` (survives upgrades).
3. `render_env` writes `$TRIM_PKGVAR/settings/retention`, `$TRIM_PKGVAR/settings/container-metrics` and `$TRIM_PKGVAR/secrets/grafana-admin-password` (mode 600).
4. Each container reads its file when it starts. There is no `.env`: Fygo OS creates the containers before `install_callback` runs and never re-creates them on start or stop.
5. Upgrades and config changes re-run `render_env`. A changed setting applies after the app is restarted from App Center.

Metrics and Grafana data live in `$TRIM_PKGVAR`. Uninstall keeps them unless the user picks "Delete them" in the uninstall dialog.

## First session on the VM

1. Snapshot the VM before activating the license (the license is tied to the NAS ID).
2. Create a storage volume, then open the Docker app and pick that volume. Docker does not start before this.
3. Install fygopack on your workstation, then from the repo root run `./scripts/validate.sh monitor` and `fygopack build --directory monitor`.
4. Copy the .fpk to the NAS and install with `appcenter-cli install-fpk fygo-monitor.fpk --env test.env`, where test.env contains:
   ```
   wizard_grafana_password=changeme123
   wizard_retention_days=15
   wizard_container_metrics=false
   ```
5. Work through the assumptions below, then repeat with `wizard_container_metrics=true`.
6. Uninstall, upgrade and settings changes only work from the web UI (App Center, Manual Install for the .fpk).

## Assumptions to verify on a real device

Checked on Fygo OS 1.2.1010 on 2026-11-25. Details in [TESTING.md](TESTING.md).

- [x] ~~Fygo OS reads the `.env` next to `docker-compose.yaml`.~~ True, but useless: Compose runs before our scripts can write it. The app no longer uses `.env`.
- [x] `TRIM_PKGVAR`, `TRIM_APPDEST`, `TRIM_SERVICE_PORT`, `TRIM_UID` and `TRIM_GID` are set when Fygo OS runs `docker compose`.
- [x] Lifecycle scripts run as the package user. It can write to `$TRIM_PKGVAR` and `$TRIM_PKGETC`. It cannot use Docker.
- [x] ~~`install_callback` runs before the Compose project is created.~~ False. Compose `create` runs first. Fixed by reading settings from files at container start.
- [x] Wizard `switch` values come through as the strings `true` / `false`.
- [x] The app icon shows in App Center and in the app window.
- [x] Grafana loads inside the Fygo desktop iframe and login works there.
- [x] Changing password, retention or container metrics takes effect after an app restart (tested by running `config_callback` as the package user, not yet through the settings screen).
- [x] Uninstall keeping data, then install again: metrics, dashboards and settings are kept, and the password from the new wizard run wins.
- [x] node-exporter and the other services come back after a NAS reboot.
- [x] A storage pool mounted after install shows up without a restart.
- [x] The ZFS metrics behind the ZFS panel have data once a pool exists (checked in Prometheus, panel not yet looked at).
- [x] The settings screen in App Center calls `config_callback` with the `wizard_*` variables and saves correctly. Fygo OS does not restart the app, so the change applies after a manual restart.
- [x] Upgrade through Manual Install over an installed version re-creates the containers and keeps metrics, dashboards, settings and the password.
- [x] Uninstall with "Delete them" selected removes metrics, dashboards and settings. The first version used a switch, which reached the script as `false` even when it was on; it is now a select with the values `keep` / `delete`.
- [ ] Fygo OS review accepts the host access listed in [PERMISSIONS.md](PERMISSIONS.md).

## Roadmap

- v0.2: SMART disk health via smartctl_exporter, plus a disk temperature panel
- v0.3: Alert rules (volume over 85%, disk failing, high temperature) with optional ntfy/Telegram notifications
- v0.4: Switch Grafana to the unified gateway socket so no host port is needed
- i18n: add `i18n/en-US` once the format is confirmed

## Submitting

Submission goes through the FygoOS developer platform. Have these ready:
- `fygo-monitor.fpk`
- Short intro and main use cases (use the top of this README)
- Screenshots of the real dashboard on a running NAS
- Publisher: Chase Dumphord, chasedumphord.com, contact email
- Link to the GitHub repo: https://github.com/ced4568/fygoos-apps
- Redistribution statement: Prometheus, node-exporter and cAdvisor are Apache-2.0. Grafana OSS is AGPL-3.0. All are pulled unmodified from their official images, and nothing is bundled inside the .fpk.

## License

MIT for the packaging in this repo. Each upstream component keeps its own license.
