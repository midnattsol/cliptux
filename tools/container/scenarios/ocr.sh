# Text recognition scenarios of the container suite (sourced by
# scenarios.sh, with lib.sh's helpers): searching the history by text, and
# the editor's text tools.
#   ocr  ocr-tools

# search WORDS...: type a search into the history panel; Esc clears the
# previous one first (with an empty one it would close the panel)
search() { [ -n "$searched" ] && keys esc; searched=1; drv type "$*"; sleep 0.6; }

scenario_ocr() {
    quick_cfg
    start_droptarget
    if ! ldconfig -p | grep -q libtesseract; then skip "no libtesseract in the image"; return; fi
    drv textpng "$OUT/en.png" 40 "Quarterly invoice from Midnattsol" || { fail "text picture"; return; }
    drv textpng "$OUT/es.png" 40 "Canción del año en España" || { fail "text picture"; return; }
    for f in en es; do
        drv png "$OUT/$f.png"
        run_shotlet "shotlet-$f" shot --from "$OUT/$f.png" --sel "0,0,${VAL%x*},${VAL#*x}"
        wait_editor 10 && keys enter
        any_log 10 "quick access: (showing|added)"
        sleep 0.5
    done
    pkill -f "shotlet quick" 2>/dev/null
    LANG=es_ES.UTF-8 run_shotlet shotlet-panel history
    check "the panel has a search field (Tesseract found)" wait_log 5 "text search on"
    check "  ... and reads both captures" wait_log 60 "history: read the text of 2 captures"
    grep "text of" "$SHOT_LOG" | sed 's/^/  /' >&2
    searched=
    search invoice
    check "search 'invoice' finds the English capture" wait_log 3 "search 'invoice': 1 shown"
    search midnattsol quarterly
    check "search 'midnattsol quarterly' (every word) finds it" wait_log 3 "search 'midnattsol quarterly': 1 shown"
    search cancion
    check "search 'cancion' finds 'Canción' (accents folded)" wait_log 3 "search 'cancion': 1 shown"
    search espana
    check "search 'espana' finds 'España'" wait_log 3 "search 'espana': 1 shown"
    search zebra
    check "search 'zebra' finds nothing" wait_log 3 "search 'zebra': 0 shown"
    shot 0 search
    keys esc esc esc
    wait_exit 5
}

# the editor's text tools: shotlet text, Copy text, Redact
scenario_ocr_tools() {
    no_quick_cfg
    if ! ldconfig -p | grep -q libtesseract; then skip "no libtesseract in the image"; return; fi
    drv textpng "$OUT/en.png" 40 "Quarterly invoice from Midnattsol" || { fail "text picture"; return; }
    drv png "$OUT/en.png"
    W=${VAL%x*} H=${VAL#*x}
    ocr_text_command
    ocr_copy_text
    ocr_redact
}

# `shotlet text` on the picture
ocr_text_command() {
    run_shotlet shotlet-text text --from "$OUT/en.png"
    wait_editor 10
    # the picture is centred on the monitor, at 1:1
    mon_size
    X0=$(((MW - W) / 2)) Y0=$(((MH - H) / 2))
    select_on 0 $((X0 + 2)) $((Y0 + 2)) $((X0 + W - 2)) $((Y0 + H - 2))
    check "shotlet text reads the region selected" wait_log 60 "copy text: [0-9]+ bytes"
    check "  ... puts its text on the clipboard" eq "$(timeout 5 wl-paste -n -t 'text/plain;charset=utf-8')" "Quarterly invoice from Midnattsol"
    check "  ... shows a toast with the first line" any_log 10 "toast: Copied: Quarterly invoice"
    timeout 5 wl-copy -- "something else"
    wait_exit 5
}

# in the editor: Copy text (Ctrl+Shift+C) on the selection
ocr_copy_text() {
    run_shotlet shotlet-copytext shot --from "$OUT/en.png" --sel "0,0,$W,$H"
    wait_editor 10
    keys ctrl+shift+c
    check "Copy text in the editor" wait_log 60 "copy text: [0-9]+ bytes"
    check "  ... copies the selection's text" eq "$(timeout 5 wl-paste -n)" "Quarterly invoice from Midnattsol"
    check "  ... and the editor stays open" alive
    keys esc esc
    wait_exit 5
    timeout 5 wl-copy -- "something else"
}

# Redact sensitive data finds an e-mail address and a token
ocr_redact() {
    drv textpng "$OUT/secret.png" 36 "Mail jane.doe@example.com key ghp_16C7e42F292c6912E7710c838347Ae178B4a" || { fail "text picture"; return; }
    drv png "$OUT/secret.png"
    W=${VAL%x*} H=${VAL#*x}
    run_shotlet shotlet-redact shot --from "$OUT/secret.png" --sel "0,0,$W,$H"
    wait_editor 10
    keys ctrl+shift+r
    check "Redact sensitive data finds the e-mail address" wait_log 60 "redact: email"
    check "  ... and the token" wait_log 5 "redact: (api_key|token)"
    grep "redact:" "$SHOT_LOG" | sed 's/^/  /' >&2
    shot 0 redacted
    keys enter
    sleep 1
    check "  ... the redacted capture copies" clip_png "$OUT/redacted-clip.png"
    # the redaction covers the address: no black text pixels left where it was
    drv findpng "$OUT/redacted-clip.png" 1c1c1e 6 40 && echo "  redaction box: $VAL" >&2
    check "  ... with a solid box over it" drv findpng "$OUT/redacted-clip.png" 1c1c1e 6 40
    timeout 5 wl-copy -- "something else"
    wait_exit 5
}
