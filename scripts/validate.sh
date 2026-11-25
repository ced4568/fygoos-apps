#!/bin/bash
# Local pre-flight check. Mirrors the fygopack package checks and adds lint steps.
# Usage: ./scripts/validate.sh [app-dir ...]
#   With no arguments, validates every top-level folder that contains a manifest.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
errors=0
ok()   { echo "  ok    $1"; }
bad()  { echo "  FAIL  $1"; errors=$((errors+1)); }

validate_app() {
    echo "Package structure (fygopack requirements)"
    for f in manifest config/privilege config/resource ICON.PNG ICON_256.PNG; do
        [ -f "$f" ] && ok "$f" || bad "$f missing"
    done
    for d in app cmd wizard app/ui; do
        [ -d "$d" ] && ok "$d/" || bad "$d/ missing"
    done

    echo "Manifest fields"
    for k in appname version display_name desc source platform maintainer service_port desktop_applaunchname; do
        grep -q "^$k=" manifest && ok "$k" || bad "$k not set"
    done

    echo "Port consistency"
    mport=$(grep '^service_port=' manifest | cut -d= -f2)
    uport=$(jq -r '.".url"[]?.port' app/ui/config 2>/dev/null | head -1)
    [ "$mport" = "$uport" ] && ok "manifest ($mport) matches app/ui/config ($uport)" || bad "manifest port $mport != ui port $uport"

    echo "JSON files"
    for f in config/privilege config/resource app/ui/config wizard/* app/docker/grafana/dashboards/*.json; do
        [ -e "$f" ] || continue   # optional files (not every app ships Grafana dashboards)
        jq empty "$f" 2>/dev/null && ok "$f" || bad "$f is not valid JSON"
    done

    echo "Wizard fields use the wizard_ prefix"
    if jq -r '.[].items[].field // empty' wizard/* | grep -v '^wizard_' | grep -q .; then
        bad "a wizard field is missing the wizard_ prefix"
    else
        ok "all fields prefixed"
    fi

    echo "Shell scripts"
    if command -v shellcheck >/dev/null; then
        shellcheck -x -e SC1090,SC1091,SC2154 cmd/* && ok "shellcheck" || bad "shellcheck"
    else
        echo "  skip  shellcheck not installed"
    fi

    echo "Compose file"
    if command -v docker >/dev/null; then
        # Same as Fygo OS at install: only TRIM_* variables, and no file written by cmd/* exists yet.
        TRIM_SERVICE_PORT="$mport" TRIM_APPDEST="$PWD/app" TRIM_PKGVAR=/nonexistent \
        TRIM_UID=1000 TRIM_GID=1000 \
            docker compose -f app/docker/docker-compose.yaml config -q && ok "docker compose config" || bad "docker compose config"
    else
        echo "  skip  docker not installed"
    fi
}

if [ "$#" -eq 0 ]; then
    cd "$root" || exit 1
    for m in */manifest; do
        [ -f "$m" ] && set -- "$@" "${m%/manifest}"
    done
    [ "$#" -gt 0 ] || { echo "No app folders found (no */manifest under $root)."; exit 1; }
fi

for app in "$@"; do
    echo "=== $app"
    if cd "$app" 2>/dev/null || cd "$root/$app" 2>/dev/null; then
        validate_app
        cd "$root" || exit 1
    else
        bad "$app is not a directory"
    fi
    echo
done

[ "$errors" -eq 0 ] && echo "All checks passed." || echo "$errors check(s) failed."
exit "$errors"
