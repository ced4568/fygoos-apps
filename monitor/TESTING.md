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
