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
| Uninstall 0.1.1 keeping data, then install 0.1.2 | Pass. Metrics from before are still there and the password from the new wizard run works. This was first logged here as an upgrade; the App Center log shows an uninstall at 02:16 and a fresh install at 02:17. A real upgrade is still untested. |
| Container metrics switched on in the install wizard | Pass. cAdvisor started. No settings change through App Center has been recorded yet. |
| cAdvisor inside the installed app | Pass. Target `up`, four containers reported by name, no "failed to identify" errors. |
| Dashboard | "Load (1m) per core" showed "No data". The division had no matching labels. Fixed with `scalar()`; the query now returns a value. |

### Third round, same day (command line)

| Check | Result |
|---|---|
| Settings script with a new password and retention 30 | Ran `cmd/config_callback` as the package user with `wizard_*` variables. Before restart: old password still valid, Prometheus still on 15d. After restart: old password 401, new password 200, retention 30d. |
| Empty password in settings | Keeps the current password. |
| Invalid retention (`abc`) | Script exits 1 and changes nothing. |
| Reboot | SSH back after 42 s, Grafana healthy 35 s later. All four containers up, restart count 0, all three targets `up`, port 9100 bound to `172.31.213.1` again. |
| Storage pool added after install | New ext4 filesystem mounted at `/vol2` while the app was running: reported within one scrape, no restart (`rslave` works). |
| Do our containers block unmounting a volume? | No. Their mounts are slave mounts. The unmount was held by Fygo OS's own `trim_file_monitor`. |
| ZFS | With a 1 GB test pool: `node_zfs_arc_size` 246 MB, `node_zfs_arc_c_max` 3.0 GB, the ZFS filesystem and pool state are reported. ARC series exist even with no pool, because Fygo OS loads the ZFS module. Pool destroyed afterwards. |
| node-exporter A: `pid: host` + `/` read-only | 1255 series |
| node-exporter B: `/` read-only only (shipped) | 1255 series, same metric names as A |
| node-exporter C: `/proc`, `/sys`, `/vol1` only | 1246 series; OS info lost, one filesystem error, one more failed collector |
| App status after reboot | `appcenter-cli list` shows `start` instead of `running`, although everything is up and `cmd/main status` exits 0. Cosmetic so far; check what the web UI shows. |

### 2026-11-26: fourth uninstall and reinstall (web UI)

| Check | Result |
|---|---|
| Uninstall 0.1.2, install 0.1.3 | App Center log: uninstall 14:33, fresh install 14:34. Again not an upgrade. |
| Data after the uninstall | Kept (oldest metric and the Grafana database date from the day before). Fourth UI uninstall that did not delete data. |
| Password from the new wizard run | Works; the previous one is rejected. |
| Load (1m) per core panel | The installed dashboard now has the `scalar()` query. |
| Fygo OS log during uninstall | `stop script error ... open /docker/docker-compose.yaml: no such file or directory`. Fygo OS builds that path with an empty app directory. The uninstall still succeeds and removes the containers and network. |

### 2026-11-26: uninstall with data deletion, clean install

| Check | Result |
|---|---|
| Old uninstall switch | Bug. Reached `uninstall_callback` as `wizard_delete_data=false` on every UI uninstall, including one where the user confirmed it was on. Replaced by a select, `wizard_data_action` with `keep` / `delete`. |
| Uninstall with "Delete them" (web UI) | Pass. Both `uninstall_init` and `uninstall_callback` received `wizard_data_action=delete`. Metrics, Grafana data, settings and the password file are gone. |
| What Fygo OS leaves behind | Empty `@appdata`, `@appconf`, `@apphome` and `@appmeta` folders for the app, and the `fygo-monitor` system user and group. Containers, network and images are removed. |
| Wizard values at uninstall | Fygo OS also passes the stored install answers (`wizard_retention_days`, `wizard_container_metrics`, `wizard_grafana_password`) to the uninstall scripts. |
| Clean install after a full delete (CLI) | Pass. New password accepted, `admin`/`admin` rejected, all three targets `up` with container metrics on. |

### Still to test on the VM (all need the web UI)

- [ ] Upgrade through Manual Install over the installed version.
- [ ] A settings change through App Center, and whether Fygo OS restarts the app.
- [ ] The Load panel fix and the ZFS panel as seen in Grafana.
