#!/bin/sh
# Fails when a file outside the Linux backend (src/platform/linux) reaches
# into it: an @import of one of its files, or std.os.linux. The core goes
# through src/platform/api.zig, the one file allowed to import the
# backend (docs/PLATFORM.md). Files still being moved out are listed in
# tools/layers-allowlist.txt and may only leave it. Run from the
# repository root (zig build check-layers does).
set -eu

backend=src/platform/linux/
seam=src/platform/api.zig
allowlist=tools/layers-allowlist.txt

# violations: "<file>: <what>" for every file outside the backend
violations() {
    find src -name '*.zig' ! -path "$backend*" | sort | xargs awk -v backend="$backend" -v seam="$seam" '
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
