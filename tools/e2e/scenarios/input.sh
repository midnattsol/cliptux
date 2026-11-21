# Editor input scenarios of tools/e2e.sh (sourced by its inner side, with
# its helpers): typing on a Spanish layout, key repeat, undo, selection
# modifiers, the clipboard both ways, Save As and an input method.
#   keyboard  clipboard  saveas  ime

# text_editor NAME MS: shotlet NAME through the portal, a selection and
# the text tool clicked into it; the scenario ends without an editor
text_editor() {
    drv_ready Meta-0
    drv move 0 800 450
    run_shotlet "$1"
    share_dialog 0 && wait_editor 10 || { fail "editor"; exit 1; }
    drag 0 200 200 0 700 500
    keys t
    click 0 260 260
    drv sleep "$2"
}

# Spanish layout (HL_LAYOUT=es): ñ is the key right of L, ´ a dead key
# right of it, ¿ is Shift + the key left of Backspace, ? is Shift + the
# key right of 0, € is AltGr+E
scenario_keyboard() {
    text_editor kb 200
    keyboard_typing
    keyboard_undo
    keyboard_shift
    keyboard_space
    keyboard_esc
    keyboard_save
}

keyboard_typing() {
    keys semicolon a n d apostrophe u space shift+equal shift+q u apostrophe e space t a l shift+minus space altgr+e
    sleep 0.3
    shot 0 typed
    keys ctrl+a ctrl+c
    sleep 0.3
    check "Spanish text with dead keys and AltGr" eq "$(timeout 5 wl-paste -n)" "ñandú ¿Qué tal? €"
    # key repeat: hold a key past the repeat delay
    keys end
    drv hold l 1500
    sleep 0.3
    shot 0 held
    # text past the selection (x >= 702) is dimmed, as it will be cut
    check "live text inside the selection is bright" drv find 0 ff453a 30 1 400 230 700 290
    check "  ... and dimmed past its edge (not exported)" no_find_exact 0 ff453a 30 1 703 230 1600 290
    keys ctrl+a ctrl+c
    sleep 0.3
    n=$(timeout 5 wl-paste -n | grep -o l | wc -l)
    echo "  held 'l' for 1.5 s: $n characters"
    check "held key repeats" test "$n" -gt 10
    check "  ... and stops on release" test "$n" -lt 120
    # Esc leaves text editing but keeps the editor
    keys esc
    sleep 0.3
    check "Esc ends text editing, editor stays" alive
    shot 0 text-done
}

# Ctrl+Z removes the text, Ctrl+Shift+Z brings it back: the first red blob
# in reading order is the text (y ~260) when it is there, else the
# toolbar's red swatch below the selection
red_y() { drv find 0 ff453a 40 && read -r _ y _ <<<"$VAL" && echo "$y"; }
keyboard_undo() {
    check "text is drawn" test "$(red_y)" -lt 400
    keys ctrl+z
    sleep 0.3
    shot 0 undone
    check "Ctrl+Z undoes the text" test "$(red_y)" -gt 400
    keys ctrl+shift+z
    sleep 0.3
    shot 0 redone
    check "Ctrl+Shift+Z redoes it" test "$(red_y)" -lt 400
    keys enter
    sleep 1
    check "  ... the annotated selection" eq "$(clip_png "$OUT/kb.png" && png_size "$OUT/kb.png")" 500x300
}

# Shift squares a selection: a 300x100 drag becomes 300x300
keyboard_shift() {
    run_shotlet shift
    wait_editor 5
    drv move 0 100 100 && drv sleep 100 && drv down
    drv key shift down
    drv move 0 300 180
    drv move 0 400 200
    drv sleep 100
    drv up
    drv key shift up
    sleep 0.3
    shot 0 shift
    keys enter
    sleep 1
    check "Shift squares the selection" eq "$(clip_png "$OUT/shift.png" && png_size "$OUT/shift.png")" 300x300
}

# Space moves the selection while dragging: from 500,300 drag to 600,400;
# with Space held move by 100,100; then on to 800,600
keyboard_space() {
    run_shotlet space
    wait_editor 5
    drv move 0 500 300 && drv sleep 100 && drv down
    drv move 0 600 400
    drv key space down
    drv move 0 650 450
    drv move 0 700 500
    drv key space up
    drv move 0 800 600
    drv sleep 100
    drv up
    sleep 0.3
    shot 0 space
    keys enter
    sleep 1
    check "Space moves the selection while dragging" eq "$(clip_png "$OUT/space.png" && png_size "$OUT/space.png")" 200x200
}

# Esc: first drops the selection, then quits
keyboard_esc() {
    run_shotlet esc
    wait_editor 5
    drag 0 100 100 0 300 300
    keys r
    keys esc
    sleep 0.3
    check "Esc with a tool and a selection keeps the editor" alive
    keys esc esc
    check "  ... further Esc presses quit" wait_exit 3
    check "  ... with status 0" eq "$RC" 0
}

# Ctrl+S saves to ~/Pictures and closes
keyboard_save() {
    run_shotlet save
    wait_editor 5
    drag 0 100 100 0 260 220
    keys ctrl+s
    check "Ctrl+S closes" wait_exit 5
    f=$(ls "$HOME"/Pictures/shotlet-*.png 2>/dev/null | head -1)
    check "Ctrl+S wrote ~/Pictures/shotlet-*.png" test -n "$f"
    check "  ... of the selection's size" eq "$(png_size "$f")" 160x120
}

scenario_clipboard() {
    text_editor clip 200
    # paste in: wl-copy offers text the way other apps do
    timeout 5 wl-copy -- "pegado €ñ¿ 漢字 👍" &
    sleep 0.5
    keys ctrl+v
    sleep 0.3
    keys ctrl+a ctrl+c
    sleep 0.3
    check "paste then copy round-trips non-ASCII text" eq "$(timeout 5 wl-paste -n)" "pegado €ñ¿ 漢字 👍"
    keys home shift+right shift+right shift+right ctrl+x
    sleep 0.3
    check "Ctrl+X cuts the selected characters" eq "$(timeout 5 wl-paste -n)" "peg"
    keys ctrl+a ctrl+c
    sleep 0.3
    check "  ... out of the text" eq "$(timeout 5 wl-paste -n)" "ado €ñ¿ 漢字 👍"
    shot 0 text
    keys esc enter
    sleep 1
    check "Enter copies the image after text editing" eq "$(clip_png "$OUT/img.png" && png_size "$OUT/img.png")" 500x300
    # the image stays pasteable, repeatedly, while shotlet serves it
    check "  ... and pastes again" clip_png "$OUT/img2.png"
    check "  ... as the same bytes" cmp -s "$OUT/img.png" "$OUT/img2.png"
    check "  ... from a still running shotlet" alive
    timeout 5 wl-copy -- "other" &
    sleep 0.5
    check "shotlet exits once another app takes the clipboard" wait_exit 5
}

scenario_saveas() {
    drv_ready Meta-0
    drv move 0 800 450
    run_shotlet saveas
    share_dialog 0 && wait_editor 10 || { fail "editor"; exit 1; }
    drag 0 300 300 0 500 450
    keys ctrl+shift+s
    # the GTK file chooser: its Save button is the accent-coloured blob
    check "Ctrl+Shift+S opens the file chooser" wait_chooser 0 15
    sleep 0.5
    shot 0 chooser
    # the proposed name is selected, minus the extension
    keys e 2 e minus s a v e enter
    check "Save As closes after the chooser" wait_exit 10
    check "  ... with status 0" eq "$RC" 0
    ls -la "$HOME/Pictures" >"$OUT/pictures.txt"
    check "  ... writing the chosen file" eq "$(png_size "$HOME/Pictures/e2e-save.png")" 200x150
    run_shotlet cancel
    wait_editor 5
    drag 0 300 300 0 500 450
    keys ctrl+shift+s
    wait_chooser 0 15
    sleep 0.5
    keys esc
    sleep 1
    shot 0 cancelled
    check "cancelling the chooser writes nothing" eq "$(ls "$HOME/Pictures" | wc -l)" 1
    if alive; then
        check "  ... and returns to the editor" test "$(drv find 0 ff453a 40 && echo found)" = found
        keys ctrl+shift+s
        wait_chooser 0 15
        sleep 0.5
        keys a g a i n enter
        check "  ... which can still save" wait_exit 10
        check "  ... the same selection" eq "$(png_size "$HOME/Pictures/again.png")" 200x150
    else
        wait "$SHOT_PID"; RC=$?
        fail "  ... and returns to the editor (shotlet exited, status $RC)"
    fi
}

scenario_ime() {
    # IBus Hangul behind gnome-shell's text-input-v3: composition shows
    # as preedit, committed syllables become text
    if ! ibus engine 2>/dev/null | grep -q hangul; then
        skip "no IBus Hangul engine (install ibus-hangul)"
        exit 0
    fi
    text_editor ime 300
    keys "#122" # Hangul key: Latin -> Hangul mode
    keys g k s
    sleep 0.3
    shot 0 preedit
    # (preedit.png: the composing syllable drawn white on dark)
    keys space g k s r m f space
    sleep 0.3
    shot 0 committed
    keys ctrl+a ctrl+c
    sleep 0.3
    check "IME composition commits Hangul text" eq "$(timeout 5 wl-paste -n)" "한 한글 "
    keys esc enter
    sleep 1
    check "  ... and the annotated image is copied" clip_png "$OUT/ime.png"
}
