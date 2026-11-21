#!/bin/sh
# Fails when a source file grows past the line limit. Files already over
# it are listed in tools/size-allowlist.txt with their size and may only
# shrink. Run from the repository root (zig build check-size does).
set -eu

limit=600
allowlist=tools/size-allowlist.txt

sources() {
    find src tools -name '*.zig' -o -name '*.sh' -path 'tools/*'
    find gnome-extension -name '*.js'
}

# allowed <file>: the allowlisted size, or nothing
allowed() {
    awk -v f="$1" '$1 !~ /^#/ && $2 == f { print $1 }' "$allowlist"
}

fail=0
for f in $(sources | sort); do
    n=$(wc -l < "$f")
    max=$(allowed "$f")
    if [ -n "$max" ]; then
        if [ "$n" -gt "$max" ]; then
            echo "$f: $n lines, grew past its allowlisted $max (limit $limit): split it" >&2
            fail=1
        elif [ "$n" -le "$limit" ]; then
            echo "$f: $n lines, now within the limit: remove it from $allowlist" >&2
        elif [ "$n" -lt "$max" ]; then
            echo "$f: $n lines, shrank: lower its entry in $allowlist to $n" >&2
        fi
    elif [ "$n" -gt "$limit" ]; then
        echo "$f: $n lines, over the $limit-line limit: split it" >&2
        fail=1
    fi
done

awk '$1 !~ /^#/ && NF { print $2 }' "$allowlist" | while read -r f; do
    [ -e "$f" ] || echo "$allowlist: $f no longer exists: remove it" >&2
done

exit $fail
