# Fygo Monitor

Prometheus + Grafana monitoring packaged as a Fygo OS app. Install it, open it from the desktop, and a NAS dashboard is already there: CPU, memory, volumes, disk I/O, ZFS ARC, network, and optionally Docker containers.

## What's in the stack

| Service | Role | Exposed |
|---|---|---|
| Grafana | UI, opened from the Fygo desktop | port 3300 |
| Prometheus | Stores metrics (retention set in the wizard) | internal only |
| node-exporter | Host metrics: CPU, memory, disks, ZFS, network | internal only |
| cAdvisor | Container metrics, off by default (needs privileged mode) | internal only |

## Project layout

```
manifest                      app metadata, port 3300
app/docker/docker-compose.yaml
app/docker/prometheus/        scrape config
app/docker/grafana/           provisioned datasource and dashboard
app/ui/config                 desktop entry (iframe to Grafana)
cmd/common                    settings -> .env rendering, shared by lifecycle scripts
cmd/*                         lifecycle scripts
config/resource               declares the Compose project
wizard/install|config|uninstall
```

Shared tooling lives at the repo root: `scripts/validate.sh` (local pre-flight checks) and `.github/workflows/build.yml` (CI: validate, build .fpk, attach to releases).

## How settings flow

1. The install wizard collects the Grafana password, retention and the container metrics toggle.
2. `install_callback` validates them and saves `$TRIM_PKGETC/settings.env` (survives upgrades).
3. `render_env` writes `app/docker/.env` (UID/GID, retention, Compose profile) and `$TRIM_PKGVAR/grafana.env` (admin credentials, mode 600).
4. Upgrades and config changes re-run `render_env`, so nothing is lost.

Metrics and Grafana data live in `$TRIM_PKGVAR`. Uninstall keeps them unless the user ticks "delete data".

## First session on the VM

1. Snapshot the VM before activating the license (the license is tied to the NAS ID).
2. Enable Docker in Fygo OS.
3. Install fygopack on your workstation, then from the repo root run `./scripts/validate.sh monitor` and `fygopack build --directory monitor`.
4. Copy the .fpk to the NAS and install with `appcenter-cli install-fpk fygo-monitor.fpk --env test.env`, where test.env contains:
   ```
   wizard_grafana_password=changeme123
   wizard_retention_days=15
   wizard_container_metrics=false
   ```
5. Work through the assumptions below, then repeat with `wizard_container_metrics=true`.

## Assumptions to verify on a real device

The docs don't cover these, so check each one:

- [ ] Fygo OS runs Compose from `$TRIM_APPDEST/docker`, so the generated `.env` is picked up. If not, move the values into `environment:` blocks.
- [ ] `TRIM_PKGVAR` and `TRIM_APPDEST` are set when Fygo OS runs `docker compose`, not only in the scripts.
- [ ] Lifecycle scripts run as the package user, and `id -u` / `id -g` give a UID that can write to `$TRIM_PKGVAR`.
- [ ] `install_callback` runs before Fygo OS first starts the Compose project. If not, the first start fails because `grafana.env` is missing.
- [ ] Wizard `switch` values come through as the strings `true` / `false`.
- [ ] The `{0}` in `images/icon_{0}.png` is replaced with a pixel size (64 and 256 are included). Rename if it isn't.
- [ ] Grafana loads inside the Fygo desktop iframe (needs `GF_SECURITY_ALLOW_EMBEDDING`, already set) and login cookies work there.
- [ ] Fygo OS allows `pid: host`, the read-only `/` mount for node-exporter and `privileged` for cAdvisor. Ask the review team if any of these will block approval.
- [ ] The ZFS panel shows data on a ZFS volume.
- [ ] Changing the password in settings updates Grafana (`config_callback` runs `grafana cli admin reset-admin-password` in the running container).
- [ ] After a config change, the app needs a restart from App Center for new settings to apply.

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
