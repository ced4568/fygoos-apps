# Fygo Monitor: test log

Newest first. FygoOS device results go here once the test VM is up.

## 2026-11-24: permission reduction (development machine, not FygoOS)

Environment: Ubuntu, kernel 7.0, Docker with cgroup v2, AppArmor, containerd image store. Images: `prom/node-exporter:v1.13.1`, `ghcr.io/google/cadvisor:v0.61.1`. Each variant ran as a standalone container and its `/metrics` output was compared with the old configuration. Full tables are in [PERMISSIONS.md](PERMISSIONS.md).

| Change | Result | Decision |
|---|---|---|
| node-exporter: remove `pid: host` | 1056 series before and after, same collectors succeed | removed |
| node-exporter: mount `/proc`, `/sys` and volumes instead of `/` | works, but loses OS info, breaks unlisted mounts, needs hard-coded volume paths | kept `/` read-only |
| cAdvisor: remove `privileged` and `/dev/kmsg` | all per-container series unchanged; OOM event counter disabled | removed |
| cAdvisor: mount `/proc` instead of `/` | all per-container series unchanged; one harmless "could not stat" log line per container | changed |
| cAdvisor: no `/proc` at all | per-container network metrics lost | rejected |
| cAdvisor: Docker socket and `/sys` only | no containers identified (needs containerd socket here) | rejected |

Also smoke-tested earlier the same day: Prometheus v3.16.0 and Grafana 13.3.1 start, the datasource and dashboard are provisioned, the retention flag applies, `grafana cli admin reset-admin-password` works.

### Bug found and fixed

- **Network panel showed the wrong interface.** node-exporter on the bridge network reported only `eth0` and `lo` of its own container. Fixed with `network_mode: host`, with the metrics port bound to the app bridge gateway `172.31.213.1:9100`.
- Full stack check after the fix (all four services via Compose, container metrics on): all three Prometheus targets `up`, real host ports reported, 6 named containers from cAdvisor, Grafana healthy, port 9100 refused on the LAN address and on loopback.

### Not tested yet (needs FygoOS)

- [ ] Repeat the node-exporter and cAdvisor variants on FygoOS. Kernel, cgroup version and Docker storage setup may differ.
- [ ] `docker info -f '{{.DockerRootDir}} {{.Driver}} {{.CgroupVersion}}'` on FygoOS. If the Docker root is not `/var/lib/docker`, fix the cAdvisor mount.
- [ ] Subnet `172.31.213.0/28` does not collide with a FygoOS Docker network, and the FygoOS firewall lets Prometheus reach `172.31.213.1:9100`.
- [ ] node-exporter comes back after a NAS reboot (it binds to the bridge address, which must exist first).
- [ ] Container CPU and memory panels show data with container metrics on.
- [ ] Volume free space shows for every storage pool, including one added after install (`rslave`).
- [ ] ZFS panel (the ZFS collector had no data on the test machine, which has no ZFS).
- [ ] Everything in the README "Assumptions to verify" list.
- [ ] Install, settings change, upgrade, uninstall with and without deleting data; again with container metrics on.

## 2026-11-25: first run on FygoOS (test VM)

Environment: FygoOS 1.2.1010 (Debian 12, kernel 6.18.18-trim) in a Proxmox VM, 4 vCPU, 4 GB RAM.
Storage volume `/vol1`: Btrfs on RAID 5 over three 8 GB disks. Docker 28.5.2, Compose v2.40.3,
overlay2, cgroup v2, AppArmor. Package built unsigned (`fygopack build --nosign`) and installed
with `appcenter-cli install-fpk fygo-monitor.fpk --env test.env`.

### How FygoOS really drives an app (observed, not from the docs)

| Step | What happens |
|---|---|
| Before anything | Docker does not start until the user picks a data volume in the Docker app. Docker's data then lives at `<volume>/docker` (here `/vol1/docker`), not `/var/lib/docker`. |
| `cmd/install_init` | Runs as the package user (`fygo-monitor`). None of the app directories exist yet, and the script cannot create them. |
| Unpack, then Compose | FygoOS runs `docker compose -f <app>/docker/docker-compose.yaml -p fygo-monitor create` as root. Compose gets the `TRIM_*` variables (including `TRIM_UID`, `TRIM_GID`, `TRIM_PKGVAR`, `TRIM_APPDEST`, `TRIM_SERVICE_PORT`). |
| `cmd/install_callback` | Runs after the containers already exist. The wizard answers arrive as `wizard_*` variables. |
| Start / stop | `docker compose start` and `docker compose stop`. Containers are never re-created. |
| `cmd/main` | Not called during install, start or stop in these runs. |
| Uninstall | Only possible from the web UI (`appcenter-cli uninstall` answers "please uninstall it from Web UI"). FygoOS removes the containers and the `fygo-monitor` network itself. |
| Upgrade | `appcenter-cli install-fpk` with a higher version answers "is installed" and changes nothing. Needs the web UI. |

Paths on this VM: `TRIM_APPDEST=/vol1/@appcenter/fygo-monitor`, `TRIM_PKGVAR=/vol1/@appdata/fygo-monitor`,
`TRIM_PKGETC=/vol1/@appconf/fygo-monitor`. The package user is not in the `docker` group.

### Bugs found and fixed

| Bug | Cause | Fix |
|---|---|---|
| Install failed and rolled back (App Center error 10266) | Compose ran before `install_callback` had written `.env` and `grafana.env`, and the missing `env_file` is fatal. | No `.env` or `env_file` any more. Containers read their settings from files under `$TRIM_PKGVAR/settings` and `$TRIM_PKGVAR/secrets` when they start. |
| Grafana came up with the default `admin` / `admin` login (seen with a quick workaround build) | The password was injected at container creation, before the wizard answer existed. | `GF_SECURITY_ADMIN_PASSWORD__FILE` points at a file written by `install_callback`. Verified: `admin`/`admin` gets 401, the wizard password gets 200. |
| Retention and the container-metrics switch could never change | Both were fixed at container creation; start/stop does not re-create. | Prometheus reads retention from a file at start. cAdvisor's container always exists and only runs cAdvisor when the switch file says `true`; otherwise it sleeps. |
| Status check and password change could not work | Both called `docker`, which the package user cannot use. | Status asks Grafana's health URL. Password change goes through the Grafana API with the old password. |
| cAdvisor found no containers ("failed to identify the read-write layer ID") | It needs Docker's data directory at its real path, which is on the storage volume. | cAdvisor mounts `/` read-only at `/rootfs`; its start script reads `data-root` from the host's `/etc/docker/daemon.json` and links it into place. Verified standalone: 5 named containers with CPU, memory, network and filesystem series. |
| Wizard said cAdvisor runs "with elevated privileges" | Stale text from before privileged mode was removed. | Label now says cAdvisor gets read-only access to the Docker socket. |

### Results so far

| Check | Result |
|---|---|
| Unsigned `.fpk` installs | Yes |
| Install with container metrics off | Pass (after the fixes). All containers up, Grafana health 200 on port 3300 from the LAN. |
| Prometheus targets | `node` and `prometheus` up. `cadvisor` down while the switch is off (expected). |
| Network panel data | Real interface `enp6s18` reported, plus Docker bridges. |
| Volume data | `/` and `/vol1` both reported. `node_md_disks` present for the RAID 5 array. |
| Dashboard provisioned | "Fygo NAS Overview" present. |
| Subnet `172.31.213.0/28` | No collision. FygoOS uses `172.17.0.0/16` and `172.18.0.0/16` (`trim-default`). |
| Port 9100 exposure | Listens only on `172.31.213.1`. Refused from the VM's LAN address and from another machine. |
| Data ownership | Prometheus and Grafana run as `999:991` (the package user); data directories are owned by it. |
| Memory with container metrics on | Grafana 395 MiB, Prometheus 52 MiB, cAdvisor 52 MiB, node-exporter 14 MiB. |
| Uninstall keeping data (web UI) | Containers and network removed. Data, settings and the `fygo-monitor` system user stay. |
| Reinstall over kept data | Works, but the old Grafana database keeps its old admin password; the new wizard password is ignored. Open issue. |

### Second round, same day (web UI)

| Check | Result |
|---|---|
| Install through Manual Install in the web UI | Pass. The wizard showed the password, retention and container-metrics fields. |
| App window | Grafana opens inside the Fygo desktop with the app icon, and login works in the iframe. |
| Reinstall over kept data | Bug: Grafana kept the old admin password and ignored the new one. Fixed: the Grafana container now applies the saved password on every start. |
| Upgrade 0.1.1 to 0.1.2 through Manual Install | Pass. Containers were re-created with the new Compose file. Metrics from before the upgrade are still there, and settings were kept. |
| Settings change: container metrics on | Saved correctly. Fygo OS did not restart the app; after a manual restart cAdvisor started. |
| cAdvisor inside the installed app | Pass. Target `up`, four containers reported by name, no "failed to identify" errors. |
| Dashboard | "Load (1m) per core" showed "No data". The division had no matching labels. Fixed with `scalar()`; the query now returns a value. |

### Still to test on the VM

- [ ] Password change in the settings wizard, then restart.
- [ ] Uninstall with "delete data" on. Both UI uninstalls so far passed `wizard_delete_data=false`.
- [ ] The Load panel fix as seen in the UI (needs one more upgrade).
- [ ] Reboot: does node-exporter come back (it binds to the bridge address)?
- [ ] New storage pool added after install shows up (`rslave`).
- [ ] ZFS panel (needs a ZFS volume; this VM has 4 GB RAM, so do it as a separate short pass).
- [ ] Repeat the node-exporter mount variants from 2026-11-24 on FygoOS.
