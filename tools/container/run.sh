#!/bin/bash
# Container e2e suite: Shotlet on wlroots (sway, labwc) and KDE (KWin),
# each scenario in a throwaway container (--rm, no network, no host
# display, bus or PipeWire mounted). See tools/container/inner.sh for what
# runs inside, and the README's "Tests" section.
#
# usage: tools/container/run.sh [--bins SHOTLET WLDRIVE DROPTARGET] [TARGET...]
#        zig build e2e-container [-- TARGET...]
# TARGET is COMPOSITOR (all its scenarios), COMPOSITOR:SCENARIO, or `all`
# (the default). Compositors: sway labwc kwin. Scenarios: see `scenarios`.
# Prints PASS/FAIL/SKIP per check; exits 1 when anything failed, 0 with a
# SKIP when neither docker nor podman is usable.
# Env: CTR_ENGINE=docker|podman   pick the engine (default: whichever works)
#      CTR_GPU=0                  never pass a GPU render node (capture and
#                                 KWin then skip)
#      CTR_PROBE='shell code'     run it in the `probe` scenario (debugging)
#      CTR_IMAGE=name             image (default shotlet-e2e:trixie; built
#                                 from tools/container/Containerfile when
#                                 missing)
#      E2E_OUT=dir                keep logs and screenshots there
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
IMAGE=${CTR_IMAGE:-shotlet-e2e:trixie}

scenarios_sway="capture multimon rotated portal record quick pin history ocr modes ocr-tools"
scenarios_labwc="capture multimon portal quick pin history"
scenarios_kwin="capture multimon portal quick pin history modes"

BIN=$ROOT/zig-out/bin/shotlet
WLDRIVE=$ROOT/zig-out/bin/shotlet-wldrive
DROP=$ROOT/zig-out/bin/shotlet-droptarget
if [ "${1:-}" = --bins ]; then
    BIN=$2 WLDRIVE=$3 DROP=$4
    shift 4
fi

engine=${CTR_ENGINE:-}
if [ -z "$engine" ]; then
    for e in docker podman; do
        command -v "$e" >/dev/null && "$e" info >/dev/null 2>&1 && { engine=$e; break; }
    done
fi
if [ -z "$engine" ]; then
    echo "SKIP container: neither docker nor podman is usable"
    exit 0
fi
for f in "$BIN" "$WLDRIVE" "$DROP"; do
    [ -x "$f" ] || { echo "run.sh: $f missing (zig build e2e-driver)" >&2; exit 2; }
done

if ! "$engine" image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "building $IMAGE (once; needs the network for apt)" >&2
    "$engine" build -t "$IMAGE" -f "$ROOT/tools/container/Containerfile" "$ROOT/tools/container" >&2 ||
        { echo "FAIL container: image build"; exit 1; }
fi

targets=("$@")
[ ${#targets[@]} -eq 0 ] && targets=(all)
runs=()
for t in "${targets[@]}"; do
    case $t in
        all) for c in sway labwc kwin; do v=scenarios_$c; for s in ${!v}; do runs+=("$c:$s"); done; done ;;
        sway | labwc | kwin) v=scenarios_$t; for s in ${!v}; do runs+=("$t:$s"); done ;;
        *:*) runs+=("$t") ;;
        *) echo "run.sh: unknown target $t" >&2; exit 2 ;;
    esac
done

if [ -n "${E2E_OUT:-}" ]; then
    OUT=$E2E_OUT; mkdir -p "$OUT"; keep=1
else
    OUT=$(mktemp -d -t shotlet-ctr.XXXXXX); keep=
fi
OUT=$(cd "$OUT" && pwd)

# run as the caller's uid so the results directory stays theirs
user_args=(--user "$(id -u):$(id -g)")
[ "$engine" = podman ] && user_args=(--userns=keep-id)

# A GPU render node (never a card/KMS node: nothing can reach a display),
# when the host has one: xdg-desktop-portal-wlr wants dmabuf formats from
# screencopy, which wlroots' pixman renderer cannot offer, and KWin only
# offers its screenshot and screencast interfaces when compositing with
# OpenGL. CTR_GPU=0 never passes one.
gpu_args=()
if [ "${CTR_GPU:-1}" != 0 ]; then
    for node in /dev/dri/renderD*; do
        [ -c "$node" ] || continue
        gpu_args=(--device "$node" --group-add "$(stat -c %g "$node")" -e CTR_RENDER_NODE="$node")
        break
    done
fi

failed=0
for r in "${runs[@]}"; do
    comp=${r%%:*} scen=${r#*:}
    mkdir -p "$OUT/$comp/$scen"
    name=shotlet-e2e-$$-$comp-$scen
    # a scenario still running after 4 minutes is stuck (inner.sh stops at
    # 5): keep what its processes are waiting on, seen from outside
    ( sleep 240 & sp=$!
      trap 'kill $sp; exit' TERM
      wait $sp
      "$engine" exec "$name" sh -c 'for p in /proc/[0-9]*; do echo "${p#/proc/} $(cat $p/wchan 2>/dev/null) $(cat $p/stat 2>/dev/null | cut -d" " -f3) $(cat $p/comm 2>/dev/null)"; done' \
          >"$OUT/$comp/$scen/stuck-host.txt" 2>&1 ) &
    watch=$!
    "$engine" run --rm --name "$name" --network none --init --shm-size 256m \
        "${user_args[@]}" "${gpu_args[@]}" \
        -e SHOTLET_CONTAINER=1 -e HOME=/tmp/home ${CTR_PROBE:+-e CTR_PROBE} ${CTR_PROBE0:+-e CTR_PROBE0} ${CTR_KWIN_LOG:+-e CTR_KWIN_LOG} ${MONITORS:+-e MONITORS} ${CTR_ROTATED:+-e CTR_ROTATED} \
        -v "$(realpath "$BIN")":/opt/shotlet/bin/shotlet:ro \
        -v "$(realpath "$WLDRIVE")":/opt/shotlet/bin/shotlet-wldrive:ro \
        -v "$(realpath "$DROP")":/opt/shotlet/bin/shotlet-droptarget:ro \
        -v "$ROOT/tools/container":/opt/shotlet/ctr:ro \
        -v "$(realpath "$BIN")":/opt/shotlet/pkg/shotlet:ro \
        -v "$ROOT/install.sh":/opt/shotlet/pkg/install.sh:ro \
        -v "$ROOT/io.github.midnattsol.Shotlet.desktop":/opt/shotlet/pkg/io.github.midnattsol.Shotlet.desktop:ro \
        -v "$ROOT/io.github.midnattsol.Shotlet.svg":/opt/shotlet/pkg/io.github.midnattsol.Shotlet.svg:ro \
        -v "$OUT/$comp/$scen":/out \
        "$IMAGE" timeout 300 /opt/shotlet/ctr/inner.sh "$comp" "$scen" \
        2>"$OUT/$comp/$scen/stderr.log" | tee "$OUT/$comp/$scen/result.txt"
    rc=${PIPESTATUS[0]}
    kill "$watch" 2>/dev/null; wait "$watch" 2>/dev/null
    # the scenarios' own notes (indented) and driver errors; the rest of
    # the session's chatter stays in stderr.log
    grep -E '^(  |driver:)' "$OUT/$comp/$scen/stderr.log" | sed "s/^/  [$comp:$scen] /" >&2
    grep -q "^FAIL" "$OUT/$comp/$scen/result.txt" && failed=1
    if [ "$rc" -ne 0 ] && ! grep -q "^FAIL" "$OUT/$comp/$scen/result.txt"; then
        echo "FAIL $comp $scen: the container exited with $rc" | tee -a "$OUT/$comp/$scen/result.txt"
        failed=1
    fi
done

echo
echo "summary: $(cat "$OUT"/*/*/result.txt | grep -c '^PASS') passed, $(cat "$OUT"/*/*/result.txt | grep -c '^FAIL') failed, $(cat "$OUT"/*/*/result.txt | grep -c '^SKIP') skipped"
if [ "$failed" -ne 0 ] || [ -n "$keep" ]; then
    echo "logs and screenshots: $OUT"
else
    rm -rf "$OUT"
fi
exit $failed
