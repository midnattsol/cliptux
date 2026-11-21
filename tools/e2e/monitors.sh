#!/bin/bash
# usage: tools/e2e/monitors.sh Meta-0=2 Meta-1=1   (inside session.sh only)
# Lays the named monitors out left to right, top aligned, at the given
# scales (the nearest scale mutter supports for the current mode), through
# org.gnome.Mutter.DisplayConfig.ApplyMonitorsConfig (temporary method).
# Prints the resulting layout, one "connector x y w h scale" line each.
set -eu
[ -n "${HL_INNER:-}" ] || { echo "monitors.sh: run inside tools/e2e/session.sh" >&2; exit 2; }
DC=(--session --dest org.gnome.Mutter.DisplayConfig --object-path /org/gnome/Mutter/DisplayConfig)
state=$(gdbus call "${DC[@]}" --method org.gnome.Mutter.DisplayConfig.GetCurrentState)
PY=python3
[ -x /usr/bin/python3 ] && PY=/usr/bin/python3
plan=$("$PY" -I - "$state" "$@" <<'EOF'
import re, sys
state, wants = sys.argv[1], sys.argv[2:]
serial = re.match(r"\(uint32 (\d+)", state).group(1)
mode_re = re.compile(r"\('([^']+)', (\d+), (\d+), [\d.]+, [\d.]+, \[([^\]]*)\], \{([^}]*)\}")
mons = {}
# monitors look like (('Meta-0', vendor, product, serial), [modes...], {...});
# logical monitors only reference them as ('Meta-0', ...) without modes
for chunk in re.split(r"\(\('", state)[1:]:
    conn = chunk.split("'")[0]
    for mode in mode_re.finditer(chunk):
        if conn not in mons or "'is-current': <true>" in mode.group(5):
            scales = [float(s) for s in mode.group(4).split(",")]
            mons[conn] = (mode.group(1), int(mode.group(2)), int(mode.group(3)), scales)
x, parts, layout = 0, [], []
for i, w in enumerate(wants):
    conn, want = w.split("=")
    mode, pw, ph, scales = mons[conn]
    scale = min(scales, key=lambda s: abs(s - float(want)))
    lw, lh = round(pw / scale), round(ph / scale)
    primary = "true" if i == 0 else "false"
    parts.append(f"({x}, 0, {scale!r}, 0, {primary}, [('{conn}', '{mode}', @a{{sv}} {{}})])")
    layout.append(f"{conn} {x} 0 {lw} {lh} {scale!r}")
    x += lw
print(serial)
print("[" + ", ".join(parts) + "]")
print("\n".join(layout))
EOF
)
serial=$(sed -n 1p <<<"$plan")
config=$(sed -n 2p <<<"$plan")
gdbus call "${DC[@]}" --method org.gnome.Mutter.DisplayConfig.ApplyMonitorsConfig \
    "$serial" 1 "$config" "@a{sv} {}" >/dev/null
sleep 0.5
sed -n '3,$p' <<<"$plan"
