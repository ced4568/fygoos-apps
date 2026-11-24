# FygoOS Apps

Apps for the [FygoOS](https://fygonas.com) App Center by Chase Dumphord. Each top-level folder is one app, packaged as a `.fpk` with the `fygopack` CLI.

## Apps

| App | Folder | Status | Description |
|---|---|---|---|
| Fygo Monitor | [monitor/](monitor/) | v0.1.0, in testing (not yet submitted) | Prometheus + Grafana monitoring with a ready-made NAS dashboard: CPU, memory, volumes, disk I/O, ZFS, network and optional Docker container metrics. |

## Build

You need `jq`, `shellcheck`, Docker (for the Compose check) and [fygopack](https://developer.fygonas.com/docs/cli/fygopack/).

```
./scripts/validate.sh                 # check every app
./scripts/validate.sh monitor         # check one app
fygopack build --directory monitor    # produces the .fpk
```

CI (`.github/workflows/build.yml`) runs the same steps for every folder that contains a `manifest`, uploads each `.fpk` as a build artifact, and attaches them to releases on `v*` tags. It needs a repo variable `FYGOPACK_URL` pointing at the Linux amd64 fygopack download. Packages are signed when the repo secrets `FYGO_DEV_KEY` and `FYGO_DEV_CRT` hold the developer key and certificate; without them CI builds unsigned test packages (`fygopack build --nosign`) and skips the release upload.

## Adding an app

Create a new top-level folder with a `manifest`. The validate script and CI pick it up automatically. Add a row to the table above.

## Docs

- [FygoOS developer docs](https://developer.fygonas.com/docs/)
- [fygopack CLI](https://developer.fygonas.com/docs/cli/fygopack/)

## License

MIT for the packaging in this repo. Each upstream component keeps its own license.
