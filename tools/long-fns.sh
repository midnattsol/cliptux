#!/bin/sh
# Lists Zig functions longer than a soft limit (default 80 lines), longest
# first. A report only: it never fails. Relies on zig fmt layout, where a
# function's closing brace sits at the indentation of its `fn` line.
set -eu

limit=${1:-80}

find src tools -name '*.zig' | sort | xargs awk -v limit="$limit" '
    FNR == 1 { depth = 0 }
    depth == 0 && /^ *(pub )?(export )?(inline )?fn [A-Za-z_][A-Za-z0-9_]*\(/ && !/;$/ {
        match($0, /^ */)
        indent = RLENGTH
        name = $0
        sub(/^ *(pub )?(export )?(inline )?fn /, "", name)
        sub(/\(.*/, "", name)
        start = FNR
        depth = 1
        if ($0 ~ /}$/) depth = 0
        next
    }
    depth == 1 {
        match($0, /^ */)
        if (RLENGTH == indent && $0 ~ /^ *}$/) {
            n = FNR - start + 1
            if (n > limit) printf "%5d  %s:%d  %s\n", n, FILENAME, start, name
            depth = 0
        }
    }
' | sort -rn
