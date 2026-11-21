# After-capture scenarios of the container suite (sourced by scenarios.sh,
# with lib.sh's helpers): the thumbnail as a layer-shell surface, pins and
# the history panel.
#   quick  pin  history

scenario_quick() {
    quick_cfg
    check "another app is up and focused" start_droptarget
    red_capture shotlet-first
    check "the thumbnail appears after Copy" any_log 10 "quick access: showing"
    check "  ... as a layer-shell surface" any_log 1 "quick access: showing .*\(layer shell\)"
    sleep 1
    shot 0 thumb
    check "  ... bottom-left, above the other app" card_red
    keys a b c
    check "the other app keeps the keyboard (typing reaches it)" drop_said 3 "^text c"
    n0=$(grep -c "^click" "$OUT/drop.log")
    click 0 14 $((MH - 14))
    sleep 0.5
    check "a click beside the card (its shadow) reaches the app below" test "$(grep -c "^click" "$OUT/drop.log")" -gt "$n0"
    click 0 $((MW / 2)) $((MH / 2))
    sleep 0.5
    check "  ... and the thumbnail stays above it" card_red
    read -r x y <<<"$(card_point 120 75)"
    drv move 0 "$x" "$y"; sleep 0.4
    shot 0 hover
    timeout 5 wl-copy -- "something else"
    read -r x y <<<"$(card_point 60 23)"
    click 0 "$x" "$y"
    sleep 1
    drv move 0 $((MW / 2)) $((MH / 3)); sleep 0.3
    keys a
    if [ "$COMP" = kwin ]; then
        # KWin keeps the keyboard on a layer surface that clicked and
        # then went back to no keyboard interactivity
        check "after a click on the card and leaving it, typing does not run its shortcuts (A: Annotate)" \
            any_log 3 "key ignored, the pointer is elsewhere"
    else
        check "after a click on the card, once the pointer leaves it, typing reaches the app again" drop_said 3 "^text a"
    fi
    check "  ... (no editor opened)" not_log "editing .* again"
    # (wl-paste maps a surface of its own on KWin, which moves the focus)
    check "the card's Copy puts the PNG back on the clipboard" eq "$(clip_png "$OUT/clip.png" && png_size "$OUT/clip.png")" "$CAP_SIZE"
    read -r x y <<<"$(card_point 120 75)"
    slow_drag 0 "$x" "$y" $((x + 40)) $((y - 40)) 400 500 600 400 800 300
    check "dragging the card drops the PNG into the app" drop_said 5 "^drop image/png [0-9]+ 89504e47"
    check "  ... and the thumbnail goes away" any_log 5 "quick access: dropped"
    sleep 0.8
    shot 0 dropped
    check "  ... from the screen" no_find 0 ff2020 40 20 0 $((MH - 220)) 320 "$MH"
}

scenario_pin() {
    quick_cfg
    start_droptarget
    red_capture shotlet-first
    any_log 10 "quick access: showing"
    sleep 1
    read -r x y <<<"$(card_point 120 75)"
    drv move 0 "$x" "$y"; sleep 0.3
    read -r x y <<<"$(card_point 219 129)"
    click 0 "$x" "$y"
    check "the card's Pin opens a pin" any_log 5 "pin: showing"
    check "  ... as a layer-shell surface" any_log 1 "pin: showing .*layer shell"
    sleep 1
    shot 0 pinned
    # 1:1 at margin 120,120 plus 14 px of shadow room
    drv findpng "$OUT/shotlet-first.png" ff2020 40 20; read -r ex ey ew eh <<<"$VAL"
    drv find 0 ff2020 40 20; read -r cx0 cy0 w0 h0 <<<"$VAL"
    check "  ... at its place, 1:1" eq "$cx0 $cy0 $w0 $h0" "$((ex + 134)) $((ey + 134)) $ew $eh"
    click 0 $((MW - 40)) 40
    sleep 0.5
    check "  ... above the app after clicking the app" find_ 0 ff2020 40 20
    keys a
    check "  ... which keeps the keyboard" drop_said 3 "^text a"
    # drag the pin by its picture: +200, +100
    slow_drag 0 400 400 450 420 500 450 550 470 600 500
    sleep 0.8
    shot 0 pin-moved
    drv find 0 ff2020 40 20; read -r cx1 cy1 _ <<<"$VAL"
    echo "  pin centre ${cx0},${cy0} -> ${cx1},${cy1}" >&2
    check "dragging the pin moves it with the pointer (+200, +100)" \
        test $((cx1 - cx0)) -ge 190 -a $((cx1 - cx0)) -le 210 -a $((cy1 - cy0)) -ge 90 -a $((cy1 - cy0)) -le 110
    keys b
    sleep 0.3
    grep -q "^text b" "$OUT/drop.log" && echo "  (after the drag the app has the keyboard)" >&2
    click 0 $((cx1 + 100)) $((cy1 + 50)); sleep 0.3
    keys c
    sleep 0.3
    grep -q "^text c" "$OUT/drop.log" && echo "  (after a click on the pin the app has the keyboard)" >&2
    keys esc
    check "Esc closes the pin" any_log 5 "pin: closed"
}

scenario_history() {
    quick_cfg
    start_droptarget
    red_capture shotlet-one
    any_log 10 "quick access: showing"
    pkill -f "shotlet quick" 2>/dev/null
    run_shotlet shotlet-panel history
    check "Recent captures lists the capture" wait_log 5 "history: 1 captures"
    sleep 1.5
    shot 0 panel
    keys tab enter
    check "Enter copies the picked capture" wait_log 5 "history: copied"
    # Esc drops the pick, a second one closes; the process stays to
    # serve the copy until another app copies
    keys esc esc
    sleep 0.5
    shot 0 closed
    check "Esc twice closes the panel" no_find 0 ff2020 40 20
    check "  ... the copy is a PNG" clip_png "$OUT/hclip.png"
    check "  ... of the capture's size" eq "$(png_size "$OUT/hclip.png")" "$CAP_SIZE"
    timeout 5 wl-copy -- "something else"
    check "  ... which then exits once another app copies" wait_exit 5
}
