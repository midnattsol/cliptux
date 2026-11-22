#!/bin/sh
# Fails when a file outside the Linux backend (src/platform/linux) reaches
# into it: an @import of one of its files, std.os.linux, or the raw
# backend (api.backend); or speaks its language in code (comments may):
# Wayland or D-Bus, X keysyms and evdev codes, GTK accelerators. The core goes through src/platform/api.zig, the
# one file allowed to import the backend; only the e2e drivers' module
# root (src/testkit.zig, Linux tooling) takes api.backend.native
# (docs/PLATFORM.md). Files still being moved out are listed in
# tools/layers-allowlist.txt and may only leave it. Run from the
# repository root (zig build check-layers does).
set -eu

backend=src/platform/linux/
seam=src/platform/api.zig
tools_root=src/testkit.zig
allowlist=tools/layers-allowlist.txt

# violations: "<file>: <what>" for every file outside the backend
violations() {
    find src -name '*.zig' ! -path "$backend*" | sort | xargs awk -v backend="$backend" -v seam="$seam" -v tools_root="$tools_root" '
        # the directory part of a path and a normalized join
        function dirname(p) { sub(/\/[^\/]*$/, "", p); return p }
        function join(dir, rel,    n, parts, out, i, k, stack) {
            n = split(dir "/" rel, parts, "/")
            k = 0
            for (i = 1; i <= n; i++) {
                if (parts[i] == "" || parts[i] == ".") continue
                if (parts[i] == "..") { if (k > 0) k--; continue }
                stack[++k] = parts[i]
            }
            out = stack[1]
            for (i = 2; i <= k; i++) out = out "/" stack[i]
            return out
        }
        {
            line = $0
            sub(/\/\/.*/, "", line)
            if (line ~ /std\.os\.linux/) print FILENAME ": std.os.linux"
            if (FILENAME != tools_root) {
                low = tolower(line)
                if (low ~ /wayland|dbus|d-bus/) print FILENAME ": names Wayland or D-Bus (the session is api.desktop.Addresses)"
                if (low ~ /keysym|evdev/ || line ~ /(^|[^A-Za-z0-9_])(KEY|BTN)_[A-Z0-9]/) print FILENAME ": X keysyms or evdev codes (keys are api/keys.zig)"
                if (low ~ /<(ctrl|control|shift|alt|super|primary|meta|hyper|mod[0-9])>/) print FILENAME ": a GTK accelerator (shortcuts are app/accel.zig)"
            }
            if (line ~ /(api\.zig"\)|api)\.backend([^A-Za-z_]|$)/ && FILENAME != tools_root && FILENAME != seam)
                print FILENAME ": uses api.backend (the core goes through the seam)"
            while (match(line, /@import\("[^"]+\.zig"\)/)) {
                rel = substr(line, RSTART + 9, RLENGTH - 11)
                line = substr(line, RSTART + RLENGTH)
                path = join(dirname(FILENAME), rel)
                if (index(path, backend) == 1 && !(FILENAME == seam && path == backend "backend.zig"))
                    print FILENAME ": imports " path
            }
        }'
}

listed() { awk '$1 !~ /^#/ && NF { print $1 }' "$allowlist" 2>/dev/null; }

fail=0
found=$(violations | sort -u)
bad=$(echo "$found" | awk -F': ' 'NF { print $1 }' | sort -u)
for f in $bad; do
    if ! listed | grep -qx "$f"; then
        echo "$found" | grep "^$f: " >&2
        fail=1
    fi
done
for f in $(listed); do
    echo "$bad" | grep -qx "$f" || echo "$allowlist: $f no longer reaches into $backend: remove it" >&2
done
[ $fail = 0 ] || echo "check-layers: go through $seam (docs/PLATFORM.md)" >&2
exit $fail
