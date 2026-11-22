# The `tools` scenario of tools/e2e.sh (sourced by its inner side, with
# its helpers): the editor's extra tools on a known picture, driven with
# the virtual keyboard and pointer. Monitor 0 is 1600x900 and so is the
# picture, so it shows at 1:1.
#   blue #2a5db0 with a white box (200,150)-(700,450) and an orange one
#   (900,200)-(1300,600)

mkdir -p "$HOME/.config/shotlet"
printf 'thumbnail=never\nhint_shown=true\n' >"$HOME/.config/shotlet/config"
IMG=$OUT/picture.png
"${PYGTK:-/usr/bin/python3}" "$ROOT/tools/e2e/mkpng.py" "$IMG" 1600 900 2a5db0 200,150,700,450,ffffff 900,200,1300,600,ff8800
drv_start Meta-0 || { fail "driver"; exit 1; }
drv key esc
drv move 0 800 450
edit_on() { # edit_on NAME: the picture in the editor, (100,100) 1300x700 selected
    run_shotlet "$1" shot --from "$IMG" --sel 100,100,1300,700
    wait_editor 10
}
# mutter gives a window that just mapped under a still pointer the
# pointer only on the next motion: arrive in two steps
arrive() { drv move 0 $(($1 - 6)) "$2" && drv sleep 150 && drv move 0 "$1" "$2" && drv sleep 150; }
clip_text() { timeout 5 wl-paste -n 2>/dev/null; }
darker() { # darker AARRGGBB RRGGBB: every channel lower
    local a=${1:2:6} b=$2 i
    for i in 0 2 4; do [ $((16#${a:$i:2})) -lt $((16#${b:$i:2})) ] || [ $((16#${b:$i:2})) = 0 ] || return 1; done
}

# --- colour picker: I, a click copies #RRGGBB, Shift+click rgb()
edit_on picker
keys i
arrive 1000 400
click 0 1000 400
sleep 0.5
shot 0 picker
check "colour picker: a click copies the hex value" eq "$(clip_text)" "#FF8800"
drv key shift down
arrive 450 300
click 0 450 300
drv key shift up
sleep 0.5
check "  ... Shift+click copies rgb()" eq "$(clip_text)" "rgb(255, 255, 255)"
check "  ... and both land in the log" grep -q "colour picker: copied #FF8800" "$SHOT_LOG"
keys esc esc esc
wait_exit 5 || stop_shotlet

# --- ruler: U, drag across the white box; its ends snap to its edges
edit_on ruler
keys u
arrive 205 300
drag 0 205 300 0 450 300 0 696 300
sleep 0.5
shot 0 ruler
check "ruler: measures the white box edge to edge (snapped)" wait_log 3 "ruler: 500.0 px  ·  500 × 0"
check "  ... and draws it on the picture" drv find 0 ff453a 40 100 150 280 750 320
keys esc esc esc
wait_exit 5 || stop_shotlet

# --- spotlight: S, around the orange box; the rest is dimmed in the copy
edit_on spotlight
keys s
arrive 900 200
drag 0 900 200 0 1100 400 0 1300 600
sleep 0.3
keys enter
sleep 1
check "spotlight: the capture copies" eq "$(clip_png "$OUT/spot.png" && png_size "$OUT/spot.png")" 1300x700
drv pixel "$OUT/spot.png" 1000 300
check "  ... the spotlit box keeps its colour" near "$VAL" ff8800
drv pixel "$OUT/spot.png" 20 20
check "  ... everything else is dimmed" darker "$VAL" 2a5db0

# --- crop: C, Enter crops to the selection; Esc then Enter copies all of it
edit_on crop
keys c enter
sleep 0.3
shot 0 cropped
keys esc enter
sleep 1
check "crop: the picture becomes the selection" eq "$(clip_png "$OUT/crop.png" && png_size "$OUT/crop.png")" 1300x700
edit_on uncrop
keys c enter ctrl+z esc enter
sleep 1
check "  ... and undo brings the whole picture back" eq "$(clip_png "$OUT/uncrop.png" && png_size "$OUT/uncrop.png")" 1600x900

# --- shotlet edit FILE
run_shotlet edit edit "$IMG"
check "edit FILE opens the picture" wait_log 10 "edit: showing .*picture.png \(1600x900\)"
sleep 1
keys enter
sleep 1
check "  ... all of it selected: Enter copies it whole" eq "$(clip_png "$OUT/edit.png" && png_size "$OUT/edit.png")" 1600x900

# --- shotlet pin: the clipboard's image
timeout 5 wl-copy -t image/png <"$OUT/crop.png" &
sleep 0.8
run_shotlet pin pin
check "pin with no file pins the clipboard's image" wait_log 10 "pin: showing the clipboard \(1300x700"
sleep 0.5
shot 0 pinned
keys esc
wait_exit 5 || stop_shotlet

# --- the magnifier follows the pointer and leaves nothing behind: swept
# over plain blue, then away, its dark ring (#1c1c1e) is nowhere on the path
run_shotlet loupe shot --from "$IMG"
wait_editor 10
arrive 300 600
for p in 320,610 350,630 390,650 430,680 480,700 530,720 580,740 620,750; do
    drv move 0 "${p%,*}" "${p#*,}" && drv sleep 40
done
drv move 0 1100 760 && drv sleep 300
shot 0 loupe
check "the magnifier leaves no trail" no_find_exact 0 1c1c1e 12 1 260 520 780 880
keys esc
wait_exit 5 || stop_shotlet

# --- beautify is per capture: an old beautify=true is not carried over;
# the panel's pin ("Apply to every capture") keeps it on for new ones
printf 'quick_access=false\nhint_shown=true\nbeautify=true\n' >"$HOME/.config/shotlet/config"
edit_on beautify-new
keys enter
sleep 1
check "a new capture starts without the beautify frame" eq "$(clip_png "$OUT/bnew.png" && png_size "$OUT/bnew.png")" 1300x700
SHOTLET_EDITOR_SCRIPT="button beautify; button beautify_always; quit" edit_on beautify-pin
wait_exit 5 || stop_shotlet
check "  ... the panel's pin stores beautify_always=true" grep -q "^beautify_always=true" "$HOME/.config/shotlet/config"
edit_on beautify-always
keys enter
sleep 1
check "  ... and then every new capture starts with it" test "$(clip_png "$OUT/balways.png" && png_size "$OUT/balways.png")" != 1300x700
printf 'quick_access=false\nhint_shown=true\n' >"$HOME/.config/shotlet/config"

# --- a PNG file dragged onto the editor opens in it
if [ -z "$PYGTK" ]; then
    skip "drop onto the editor: no Python GTK 4"
else
    "$PYGTK" "$ROOT/tools/e2e/mkpng.py" "$OUT/small.png" 400 300 33aa55
    : >"$OUT/target.log"
    "$PYGTK" "$ROOT/tools/e2e/target.py" --source "$OUT/small.png" >>"$OUT/target.log" 2>>"$OUT/target.err" &
    TGT_PID=$!
    for i in $(seq 1 50); do grep -q "^active True" "$OUT/target.log" && break; sleep 0.2; done
    # start dragging the file, then let the editor come up under it
    arrive 800 500 && drv down && drv sleep 150
    for d in 4 10 20 40 60; do drv move 0 $((800 + d)) $((500 + d)) && drv sleep 120; done
    target_said 5 "^drag begin" || echo "  (no drag begin)" >&2
    edit_on drop
    for d in 0 10 20 30; do drv move 0 $((700 + d)) 450 && drv sleep 200; done
    drv up
    check "a PNG file dropped on the editor opens in it" wait_log 5 "drop: opened .*small.png \(400x300\)"
    sleep 0.5
    shot 0 dropped
    keys enter
    sleep 1
    check "  ... and copies as itself" eq "$(clip_png "$OUT/drop.png" && png_size "$OUT/drop.png")" 400x300
    kill "$TGT_PID" 2>/dev/null
fi
drv_stop
