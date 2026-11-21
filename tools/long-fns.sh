#!/bin/sh
# Lists functions longer than a soft limit (default 80 lines), longest
# first: Zig in src/ and tools/, shell in tools/, JavaScript in
# gnome-extension/. A report only: it never fails. Relies on formatted
# code, where a function's closing brace sits at the indentation of its
# first line; a function nested in another counts toward the outer one.
set -eu

limit=${1:-80}

{
    find src tools -name '*.zig'
    find tools -name '*.sh'
    find gnome-extension -name '*.js'
} | sort | xargs awk -v limit="$limit" '
    FNR == 1 {
        depth = 0
        if (FILENAME ~ /\.zig$/) head = "^ *(pub )?(export )?(inline )?fn [A-Za-z_][A-Za-z0-9_]*\\(.*[^;]$"
        else if (FILENAME ~ /\.sh$/) head = "^ *[A-Za-z_][A-Za-z0-9_]*\\(\\) *\\{"
        else head = "^ *((async|static|get|set) )*(function\\*? *)?[A-Za-z_$][A-Za-z0-9_$]*\\([^()]*\\) *\\{$"
    }
    depth == 0 && $0 ~ head && $0 !~ /^ *(if|for|while|switch|catch|return)\>/ {
        match($0, /^ */)
        indent = RLENGTH
        name = $0
        sub(/^ *((pub|export|inline|async|static|get|set) )*(fn |function\*? *)?/, "", name)
        sub(/\(.*/, "", name)
        start = FNR
        depth = 1
        # a shell one-liner that wraps ends at the first line ending in }
        inline_end = $0 !~ /\{ *(#.*)?$/
        if ($0 ~ /}$/) depth = 0
        next
    }
    depth == 1 {
        match($0, /^ */)
        if (inline_end ? $0 ~ /}$/ : RLENGTH == indent && $0 ~ /^ *}[;,)]*$/) {
            n = FNR - start + 1
            if (n > limit) printf "%5d  %s:%d  %s\n", n, FILENAME, start, name
            depth = 0
        }
    }
' | sort -rn
