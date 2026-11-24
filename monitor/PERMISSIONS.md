# Fygo Monitor: host access and permissions

For the FygoOS app review team. This lists every piece of host-level access the app asks for, why, and what was tried to reduce it.

App version 0.1.0. Last updated 2026-11-24.

## Summary

| Service | Runs as | Host access | On by default |
|---|---|---|---|
| Prometheus | app user (`APP_UID:APP_GID`) | none | yes |
| Grafana | app user (`APP_UID:APP_GID`) | none (one published port) | yes |
| node-exporter | `nobody` (image default) | read-only mount of `/`; host network, metrics port bound to the app bridge only | yes |
| cAdvisor | root inside the container | read-only `/proc`, `/sys`, `/var/run` (includes the Docker socket), `/var/lib/docker` | **no**, user opts in |

No service uses `privileged`, `pid: host`, `cap_add` or `devices`. One service, node-exporter, uses `network_mode: host`. An earlier draft used `pid: host` (node-exporter) and `privileged` plus `/dev/kmsg` (cAdvisor). Both were removed after the tests below.

The one item that deserves the closest look is cAdvisor's access to the Docker socket. See "cAdvisor" below.

## Full Compose config

Source of truth: `app/docker/docker-compose.yaml`. Copied here as shipped.

```yaml
# Fygo Monitor stack
# Variables:
#   TRIM_SERVICE_PORT, TRIM_PKGVAR, TRIM_APPDEST  -> provided by Fygo OS
#   APP_UID, APP_GID, PROM_RETENTION, COMPOSE_PROFILES -> written to .env by cmd/common (render_env)
# Image tags are pinned (last bumped 2026-11-24). Check for newer stable releases before each release.

name: fygo-monitor

services:
  prometheus:
    image: prom/prometheus:v3.16.0
    container_name: fygo-monitor-prometheus
    restart: unless-stopped
    user: "${APP_UID}:${APP_GID}"
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --storage.tsdb.retention.time=${PROM_RETENTION:-15d}
      - --web.enable-lifecycle
    volumes:
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
    profiles: ["containers"]   # enabled only when the user turns on container metrics in the wizard
    # Not privileged, no /dev/kmsg, no / mount. Tested 2026-11-24: only OOM event
    # counts are lost (see PERMISSIONS.md).
    command:
      - --docker_only=true
      - --housekeeping_interval=30s
    volumes:
      - "/proc:/rootfs/proc:ro"   # per-container network stats
      - "/var/run:/var/run:ro"
      - "/sys:/sys:ro"
      - "/var/lib/docker/:/var/lib/docker:ro"
    networks: [monitor]

  grafana:
    image: grafana/grafana:13.3.1
    container_name: fygo-monitor-grafana
    restart: unless-stopped
    user: "${APP_UID}:${APP_GID}"
    depends_on: [prometheus]
    ports:
      - "${TRIM_SERVICE_PORT}:3000"
    env_file:
      - "${TRIM_PKGVAR}/grafana.env"   # admin password lives here, written by cmd/common
    environment:
      GF_SECURITY_ALLOW_EMBEDDING: "true"     # required: Fygo opens the app in an iframe
      GF_ANALYTICS_REPORTING_ENABLED: "false"
      GF_ANALYTICS_CHECK_FOR_UPDATES: "false"
      GF_USERS_ALLOW_SIGN_UP: "false"
      GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH: /var/lib/grafana-dashboards/fygo-nas-overview.json
    volumes:
      - "${TRIM_PKGVAR}/grafana:/var/lib/grafana"
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

`TRIM_*` variables come from FygoOS. `APP_UID`, `APP_GID`, `PROM_RETENTION` and `COMPOSE_PROFILES` are written to `.env` by `cmd/common`.

## Per service

### Prometheus

| Item | Value | Why |
|---|---|---|
| User | `APP_UID:APP_GID` | Writes only to its own data folder |
| Mount | `$TRIM_APPDEST/docker/prometheus/prometheus.yml` read-only | Scrape config shipped in the package |
| Mount | `$TRIM_PKGVAR/prometheus` read-write | Metric storage |
| Ports | none published | Reached only by Grafana on the private `fygo-monitor` network |
| Capabilities | Docker defaults, none added | |

### Grafana

| Item | Value | Why |
|---|---|---|
| User | `APP_UID:APP_GID` | Writes only to its own data folder |
| Mount | `$TRIM_PKGVAR/grafana` read-write | Grafana database |
| Mount | `$TRIM_APPDEST/docker/grafana/provisioning` and `dashboards` read-only | Datasource and dashboard shipped in the package |
| File | `$TRIM_PKGVAR/grafana.env` | Admin password set in the wizard |
| Port | `$TRIM_SERVICE_PORT` to container 3000 | The app UI |
| Setting | `GF_SECURITY_ALLOW_EMBEDDING=true` | FygoOS opens the app in an iframe |
| Capabilities | Docker defaults, none added | |

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

Off by default. It starts only if the user turns on "container metrics" in the install or settings wizard (Compose profile `containers`).

| Item | Value | Why |
|---|---|---|
| User | root in the container (image default) | Reads cgroup files and other containers' `/proc/<pid>` entries |
| Mount | `/proc` at `/rootfs/proc`, read-only | Per-container network counters |
| Mount | `/sys` read-only | cgroup CPU, memory and I/O counters |
| Mount | `/var/run` read-only | Docker and containerd sockets, to map cgroups to container names |
| Mount | `/var/lib/docker` read-only | Container metadata and layer sizes |
| Ports | none published | |
| Capabilities | Docker defaults, none added | |
| Flag | `--docker_only=true` | Reports Docker containers only, not every host cgroup |

**The Docker socket is the sensitive part.** A read-only bind mount does not make a socket read-only. A process that can reach the Docker socket can ask Docker to do anything, which is equal to root on the NAS. cAdvisor only issues read calls (list and inspect), but the access itself is broad. That is why the feature is opt-in and the service has no published port.

Alternatives tested:

- **Drop `privileged` and `/dev/kmsg`.** Adopted. Every per-container metric is unchanged. The only loss is the OOM kill counter (`container_oom_events_total` stays at 0), which the dashboard does not use.
- **Drop the `/` mount, keep only `/proc`.** Adopted. Same metrics. cAdvisor logs one "could not stat" line per container for log-folder size, which is harmless.
- **Drop `/proc` as well.** Rejected. Per-container network metrics disappear.
- **Mount only the two socket files instead of `/var/run`, and drop `/var/lib/docker`.** Works on the test machine, but the socket paths depend on how Docker is set up on FygoOS, so this waits for device testing.
- **Docker socket only, no containerd socket.** Rejected on the test machine. cAdvisor could not identify any container. This may differ on FygoOS if Docker there does not use the containerd image store.
- **Read-only Docker API proxy in front of the socket.** Not adopted. It adds a fifth container and cAdvisor on the test machine also needed the containerd socket, which a Docker API proxy does not cover.

## Test results

Run on 2026-11-24 on a development machine, **not on FygoOS**: Ubuntu, kernel 7.0, Docker with cgroup v2, AppArmor, containerd image store. All of this is repeated on a FygoOS device before submission and logged in [TESTING.md](TESTING.md).

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
| B. A without `privileged` and `/dev/kmsg` | same 55 series; OOM event detection disabled |
| C. B without the `/` mount | per-container network metrics lost (47 series) |
| F. B with `/proc` instead of `/` **(shipped)** | same 55 series |
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
