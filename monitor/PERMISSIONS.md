# Fygo Monitor: host access and permissions

For the FygoOS app review team. This lists every piece of host-level access the app asks for, why, and what was tried to reduce it.

App version 0.1.0. Last updated 2026-11-25, after the first test run on FygoOS 1.2.1010.

## Summary

| Service | Runs as | Host access | Active by default |
|---|---|---|---|
| Prometheus | package user (`TRIM_UID:TRIM_GID`) | none | yes |
| Grafana | package user (`TRIM_UID:TRIM_GID`) | none (one published port) | yes |
| node-exporter | `nobody` (image default) | read-only mount of `/`; host network, metrics port bound to the app bridge only | yes |
| cAdvisor | root inside the container | read-only `/`, `/sys`, `/var/run` (includes the Docker socket) | **no**: the container exists but only sleeps until the user opts in |

No service uses `privileged`, `pid: host`, `cap_add` or `devices`. One service, node-exporter, uses `network_mode: host`. An earlier draft used `pid: host` (node-exporter) and `privileged` plus `/dev/kmsg` (cAdvisor). Both were removed after the tests below.

Two items deserve the closest look, both on cAdvisor: its access to the Docker socket, and the fact that its container is created with those mounts even when the feature is off. See "cAdvisor" below.

The lifecycle scripts in `cmd/` run as the package user and never call Docker.

## Full Compose config

Source of truth: `app/docker/docker-compose.yaml`. Copied here as shipped.

```yaml
# Fygo Monitor stack
# Variables:
#   TRIM_SERVICE_PORT, TRIM_PKGVAR, TRIM_APPDEST, TRIM_UID, TRIM_GID -> provided by Fygo OS
#
# Fygo OS runs "docker compose create" BEFORE cmd/install_callback, and start/stop never
# re-create containers (tested on Fygo OS 1.2.1010). So nothing here may depend on a .env or
# env_file written by our scripts. User settings are read from files at container START instead:
#   ${TRIM_PKGVAR}/settings/retention           e.g. "15d"
#   ${TRIM_PKGVAR}/settings/container-metrics   "true" or "false"
#   ${TRIM_PKGVAR}/secrets/grafana-admin-password
# cmd/common (render_env) writes them. A settings change applies on the next app restart.
# Image tags are pinned (last bumped 2026-11-24). Check for newer stable releases before each release.

name: fygo-monitor

services:
  prometheus:
    image: prom/prometheus:v3.16.0
    container_name: fygo-monitor-prometheus
    restart: unless-stopped
    user: "${TRIM_UID}:${TRIM_GID}"
    entrypoint: ["/bin/sh", "-c"]
    command:
      - >-
        exec /bin/prometheus
        --config.file=/etc/prometheus/prometheus.yml
        --storage.tsdb.path=/prometheus
        --storage.tsdb.retention.time="$$(cat /etc/fygo-monitor/retention 2>/dev/null || echo 15d)"
        --web.enable-lifecycle
    volumes:
      - "${TRIM_PKGVAR}/settings:/etc/fygo-monitor:ro"
      - "${TRIM_APPDEST}/docker/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro"
      - "${TRIM_PKGVAR}/prometheus:/prometheus"
    networks: [monitor]
    # No ports published: Prometheus is internal only.

  node-exporter:
    image: prom/node-exporter:v1.13.1
    container_name: fygo-monitor-node-exporter
    restart: unless-stopped
    # No pid: host. Tested 2026-11-24: identical metrics without it (see PERMISSIONS.md).
    # Host networking so the network panel shows the real NAS ports, not the container's eth0.
    # The metrics port listens only on the fygo-monitor bridge address, not on the LAN.
    network_mode: host
    depends_on: [prometheus]   # the bridge address must exist before node-exporter binds to it
    command:
      - --web.listen-address=172.31.213.1:9100
      - --path.rootfs=/host
      - --path.procfs=/host/proc
      - --path.sysfs=/host/sys
      - --collector.filesystem.mount-points-exclude=^/(dev|proc|sys|run|var/lib/docker/.+|var/lib/containers/.+)($$|/)
    volumes:
      - "/:/host:ro,rslave"

  cadvisor:
    image: ghcr.io/google/cadvisor:v0.61.1
    container_name: fygo-monitor-cadvisor
    restart: unless-stopped
    # Not privileged, no /dev/kmsg. Tested 2026-11-24: only OOM event counts are lost
    # (see PERMISSIONS.md).
    # The container always exists (Fygo OS creates it before the wizard answers are saved, so a
    # Compose profile cannot work). cAdvisor itself only runs when the user turned container
    # metrics on; otherwise the container sleeps and reads nothing.
    # Fygo OS keeps Docker's data on a storage volume the user picks (e.g. /vol1/docker), and
    # cAdvisor must see it at that same path or it finds no containers. The path is unknown
    # when the container is created, so the read-only / mount is needed: the start script
    # reads data-root from the host's daemon.json and links it into place.
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        if [ "$$(cat /etc/fygo-monitor/container-metrics 2>/dev/null)" != "true" ]; then
          echo "Container metrics are off. Turn them on in the app settings, then restart the app."
          exec sleep infinity
        fi
        root=$$(sed -n 's/.*"data-root" *: *"\([^"]*\)".*/\1/p' /rootfs/etc/docker/daemon.json 2>/dev/null)
        root=$${root:-/var/lib/docker}
        mkdir -p "$$(dirname "$$root")" && ln -sfn "/rootfs$$root" "$$root"
        exec /usr/bin/cadvisor --docker_only=true --housekeeping_interval=30s
    healthcheck:
      disable: true   # the image's check would mark the sleeping container unhealthy
    volumes:
      - "${TRIM_PKGVAR}/settings:/etc/fygo-monitor:ro"
      - "/:/rootfs:ro,rslave"
      - "/var/run:/var/run:ro"
      - "/sys:/sys:ro"
    networks: [monitor]

  grafana:
    image: grafana/grafana:13.3.1
    container_name: fygo-monitor-grafana
    restart: unless-stopped
    user: "${TRIM_UID}:${TRIM_GID}"
    depends_on: [prometheus]
    # Grafana only reads the password file when it creates its database. Applying it on every
    # start makes the app settings the one source of truth: a password change, or a reinstall
    # over kept data, takes effect on the next start. A password changed inside Grafana is
    # overwritten by the saved one at the next start.
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        f=/etc/fygo-monitor-secrets/grafana-admin-password
        if [ -f /var/lib/grafana/grafana.db ] && [ -s "$$f" ]; then
          grafana cli --homepath /usr/share/grafana admin reset-admin-password --password-from-stdin < "$$f" >/dev/null 2>&1 \
            || echo "Could not apply the saved admin password."
        fi
        exec /run.sh
    ports:
      - "${TRIM_SERVICE_PORT}:3000"
    environment:
      GF_SECURITY_ADMIN_USER: admin
      GF_SECURITY_ADMIN_PASSWORD__FILE: /etc/fygo-monitor-secrets/grafana-admin-password
      GF_SECURITY_ALLOW_EMBEDDING: "true"     # required: Fygo opens the app in an iframe
      GF_ANALYTICS_REPORTING_ENABLED: "false"
      GF_ANALYTICS_CHECK_FOR_UPDATES: "false"
      GF_USERS_ALLOW_SIGN_UP: "false"
      GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH: /var/lib/grafana-dashboards/fygo-nas-overview.json
    volumes:
      - "${TRIM_PKGVAR}/grafana:/var/lib/grafana"
      - "${TRIM_PKGVAR}/secrets:/etc/fygo-monitor-secrets:ro"
      - "${TRIM_APPDEST}/docker/grafana/provisioning:/etc/grafana/provisioning:ro"
      - "${TRIM_APPDEST}/docker/grafana/dashboards:/var/lib/grafana-dashboards:ro"
    networks: [monitor]

networks:
  monitor:
    name: fygo-monitor
    # ponytail: fixed subnet so node-exporter has a known address to bind to. If it collides
    # with an existing Docker network, change it here, in node-exporter's listen address
    # and in prometheus.yml.
    ipam:
      config:
        - subnet: 172.31.213.0/28
          gateway: 172.31.213.1
```

Every variable is a `TRIM_*` variable from FygoOS. The app writes no `.env` file.

## Why settings are read from files

On FygoOS 1.2.1010 the installer runs `docker compose create` before the app's `install_callback` script, and start/stop never re-create containers. So the wizard answers cannot be Compose variables. Instead `cmd/common` writes three small files, and each container reads its own when it starts:

| File | Read by | Content |
|---|---|---|
| `$TRIM_PKGVAR/settings/retention` | Prometheus | for example `15d` |
| `$TRIM_PKGVAR/settings/container-metrics` | cAdvisor | `true` or `false` |
| `$TRIM_PKGVAR/secrets/grafana-admin-password` (mode 600) | Grafana only | the admin password from the wizard |

This is why three services override `entrypoint` with a short shell script. Each script reads its file and then starts the normal program. A settings change takes effect when the user restarts the app.

## Per service

### Prometheus

| Item | Value | Why |
|---|---|---|
| User | `TRIM_UID:TRIM_GID` | Writes only to its own data folder |
| Mount | `$TRIM_APPDEST/docker/prometheus/prometheus.yml` read-only | Scrape config shipped in the package |
| Mount | `$TRIM_PKGVAR/prometheus` read-write | Metric storage |
| Mount | `$TRIM_PKGVAR/settings` read-only | Retention setting |
| Ports | none published | Reached only by Grafana on the private `fygo-monitor` network |
| Capabilities | Docker defaults, none added | |

### Grafana

| Item | Value | Why |
|---|---|---|
| User | `TRIM_UID:TRIM_GID` | Writes only to its own data folder |
| Mount | `$TRIM_PKGVAR/grafana` read-write | Grafana database |
| Mount | `$TRIM_APPDEST/docker/grafana/provisioning` and `dashboards` read-only | Datasource and dashboard shipped in the package |
| Mount | `$TRIM_PKGVAR/secrets` read-only | Admin password set in the wizard. Mounted into this container only |
| Port | `$TRIM_SERVICE_PORT` to container 3000 | The app UI |
| Setting | `GF_SECURITY_ALLOW_EMBEDDING=true` | FygoOS opens the app in an iframe |
| Capabilities | Docker defaults, none added | |

The start script applies the saved admin password with `grafana cli admin reset-admin-password` before Grafana starts. Without it, a reinstall over kept data left the old password in place and ignored the new one from the wizard.

### node-exporter

| Item | Value | Why |
|---|---|---|
| User | `nobody` (image default) | Not root, so no effective capabilities |
| Mount | `/` at `/host`, read-only, `rslave` | See below |
| Network | `network_mode: host` | See below |
| Listen address | `172.31.213.1:9100` only | The app's own bridge gateway. Not reachable from the LAN or on loopback |
| Capabilities | Docker defaults, none added | |

Why host networking: on a bridge network node-exporter can only count traffic on its own container interface. Host networking is the only way it can read the NAS network ports. It opens no ports on the LAN: the metrics endpoint binds to the gateway address of the app's private bridge (`fygo-monitor`, fixed subnet `172.31.213.0/28`), where only Prometheus reaches it. The process still runs as `nobody` with no added capabilities, so it cannot change network settings or sniff traffic.

Alternative tested: staying on the bridge network. Rejected, because the network panel then shows only the container's `eth0`.

Why the read-only `/` mount: node-exporter reads CPU, memory, disk I/O and ZFS numbers from `/host/proc` and `/host/sys`, and gets volume free space by calling `statfs` on every mount point it finds in the host mount table. It can only do that for paths it can see. `rslave` lets it see volumes that are mounted after the container starts, such as a storage pool added later. It never writes; the mount is read-only.

Alternatives tested (results in the table below):

- **Drop `pid: host`.** Adopted. No metric changed.
- **Mount only `/proc`, `/sys` and named volume paths instead of `/`.** Works, but not adopted for 0.1.0:
  - Every volume path has to be written into the Compose file, so a new storage pool shows no data until the app is updated or reinstalled.
  - Any host mount not listed reports an error instead of usage.
  - The system disk figure becomes wrong whenever Docker's data folder is on a different disk from `/`, because the exporter then measures the container's own filesystem.
  - OS name and version metrics are lost (needs `/etc/os-release`).

  If the review team requires it, this can be done: tell me the fixed volume path pattern on FygoOS and I will switch to explicit mounts.

### cAdvisor (optional)

Inactive by default. The container is always created, because FygoOS creates containers before the wizard answers are saved, so a Compose profile cannot decide it. Its start script checks the `container-metrics` setting. If it is not `true`, the script runs `sleep infinity` and nothing else: cAdvisor does not start, and nothing reads the socket or the mounts. The mounts are attached to the sleeping container all the same.

| Item | Value | Why |
|---|---|---|
| User | root in the container (image default) | Reads cgroup files and other containers' `/proc/<pid>` entries |
| Mount | `/` at `/rootfs`, read-only, `rslave` | Docker's data folder at its real path, plus `/proc` for per-container network counters. See below |
| Mount | `/sys` read-only | cgroup CPU, memory and I/O counters |
| Mount | `/var/run` read-only | Docker and containerd sockets, to map cgroups to container names |
| Mount | `$TRIM_PKGVAR/settings` read-only | The on/off setting |
| Ports | none published | |
| Capabilities | Docker defaults, none added | |
| Flag | `--docker_only=true` | Reports Docker containers only, not every host cgroup |

**The Docker socket is the sensitive part.** A read-only bind mount does not make a socket read-only. A process that can reach the Docker socket can ask Docker to do anything, which is equal to root on the NAS. cAdvisor only issues read calls (list and inspect), but the access itself is broad. That is why the feature is opt-in and the service has no published port.

**Why the read-only `/` mount came back.** On FygoOS, Docker's data folder is on the storage volume the user picks in the Docker app (`/vol1/docker` on the test VM), not `/var/lib/docker`. cAdvisor has to see that folder at the same path Docker reports, or it identifies no containers ("failed to identify the read-write layer ID"). The path is not known when the container is created and FygoOS does not pass it to Compose. So the start script reads `data-root` from the host's `/etc/docker/daemon.json` and links `/rootfs<data-root>` to that path inside the container.

If the review team prefers a narrower mount, either of these would allow it: a `TRIM_*` variable with the Docker data path available to Compose, or a fixed path (for example a symlink) that always points at it. I would then mount only that folder and `/proc`.

Alternatives tested:

- **Drop `privileged` and `/dev/kmsg`.** Adopted. Every per-container metric is unchanged. The only loss is the OOM kill counter (`container_oom_events_total` stays at 0), which the dashboard does not use.
- **Mount only `/proc` and `/var/lib/docker` instead of `/`.** Worked on the development machine. Rejected after the FygoOS test: no containers are identified, because Docker's data is not in `/var/lib/docker`.
- **Drop `/proc` as well.** Rejected. Per-container network metrics disappear.
- **Create the cAdvisor container only when the user opts in (Compose profile).** Rejected after the FygoOS test: containers are created before the wizard answers reach the app, and the app's scripts cannot run Docker to create it later.
- **Run the app's scripts as root so they can manage the container themselves.** Not adopted. It is a larger privilege than a sleeping container.
- **Docker socket only, no containerd socket.** Rejected on the development machine. cAdvisor could not identify any container.
- **Read-only Docker API proxy in front of the socket.** Not adopted. It adds a fifth container and does not cover the containerd socket.

## Test results

Run on 2026-11-24 on a development machine, **not on FygoOS**: Ubuntu, kernel 7.0, Docker with cgroup v2, AppArmor, containerd image store. The FygoOS results are in the next section and in [TESTING.md](TESTING.md).

node-exporter v1.13.1:

| Variant | Series | Result |
|---|---|---|
| A. `pid: host` + `/` read-only (old) | 1056 | baseline |
| B. `/` read-only only **(shipped)** | 1056 | identical to A, same collectors succeed |
| C. `/proc`, `/sys` and one data volume only | 1040 | OS info lost; unlisted mounts (`/boot/efi`, `/tmp`) report errors; `/` figure comes from the container filesystem |
| D. C plus `pid: host` | 1040 | same as C |

cAdvisor v0.61.1 (compared on one running container, 55 metric series in the baseline):

| Variant | Result |
|---|---|
| A. `privileged` + `/dev/kmsg` + `/`, `/var/run`, `/sys`, `/var/lib/docker` (old) | baseline |
| B. A without `privileged` and `/dev/kmsg` **(shipped, minus the separate `/var/lib/docker` mount)** | same 55 series; OOM event detection disabled |
| C. B without the `/` mount | per-container network metrics lost (47 series) |
| F. B with `/proc` instead of `/` | same 55 series on this machine; finds no containers on FygoOS (see below) |
| G. F with socket files only, no `/var/lib/docker` | same 55 series |
| D. Docker socket and `/sys` only | no containers identified |

Effective capabilities inside cAdvisor went from the full set (`000001ffffffffff`, privileged) to the Docker default set (`00000000a80425fb`).

Host networking for node-exporter (full stack, all four services, same machine):

| Check | Result |
|---|---|
| Bridge network (old) | reports only the container's `eth0` and `lo` |
| `network_mode: host` **(shipped)** | reports the real ports (`enp0s31f6`, `wlp3s0`, ...); Prometheus target `up` |
| Listening sockets on the host | `172.31.213.1:9100` only |
| `curl` to the LAN address and to `127.0.0.1` on port 9100 | refused |

## Results on FygoOS

Run on 2026-11-25 on FygoOS 1.2.1010 in a VM: Docker 28.5.2, overlay2, cgroup v2, AppArmor, Docker data on `/vol1/docker` (Btrfs, RAID 5). Full log in [TESTING.md](TESTING.md).

| Check | Result |
|---|---|
| Prometheus and Grafana user | `999:991`, the package user FygoOS created |
| node-exporter with `/` read-only and host network | target `up`; real port `enp6s18`, volumes `/` and `/vol1`, and the RAID array are reported |
| Port 9100 | listens on `172.31.213.1` only; refused on the LAN address, also from another machine |
| Subnet `172.31.213.0/28` | no collision with FygoOS networks (`172.17.0.0/16`, `172.18.0.0/16`) |
| cAdvisor, container metrics off | process list shows only `sleep infinity` |
| cAdvisor with `/proc` and `/var/lib/docker` mounts (old) | no containers identified |
| cAdvisor with read-only `/` and the data-root link **(shipped)** | all four app containers reported by name; CPU, memory, network and filesystem series present; target `up` |
| Grafana admin login | default `admin`/`admin` rejected; wizard password accepted |

Not yet run on FygoOS: the node-exporter narrow-mount variants C and D, and the ZFS collector.
