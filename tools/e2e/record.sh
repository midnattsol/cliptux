# Screen recording scenarios (rec-*), sourced by tools/e2e.sh inside the
# private session, with its helpers (drv, check, shell_wait, ...).
#
#   rec-shell    MP4 of an area through the GNOME extension: no dialog,
#                the size, codec and rate, pictures that change, the
#                click ripples recorded, StartRecording from another
#                program refused, the thumbnail and the history entry
#   rec-gif      the same as a GIF (decoded and checked), and pause
#   rec-trim     the trim window makes a shorter file
#   rec-portal   without the extension: the ScreenCast portal, one
#                consent, then none (restore token)

command -v ffprobe >/dev/null || { skip "no ffprobe"; exit 0; }

# probe FILE ENTRIES: one ffprobe value list (csv)
probe() { ffprobe -v error -select_streams v:0 -show_entries "$2" -of csv=p=0 "$1" 2>/dev/null | head -1; }
duration_ms() { ffprobe -v error -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null | awk '{ printf "%d", $1 * 1000 }'; }
# frame FILE SECONDS PNG: one picture of the video
frame() { ffmpeg -v error -y -ss "$2" -i "$1" -frames:v 1 "$3" 2>/dev/null; }
# a recording of AREA for SECONDS, the pointer moving across it
record_moving() { # record_moving NAME AREA SECONDS ARGS...
    local name=$1 area=$2 secs=$3; shift 3
    run_shotlet "$name" record --region "$area" --seconds "$secs" --no-countdown "$@"
    wait_log 15 "record: recording" || return 1
    local x
    for x in 220 300 380 460 540 460 380; do drv move 0 "$x" 300; drv sleep 200; done
    wait_exit $((secs + 20))
}
saved_file() { grep -o "recording: saved [^ ]*" "$SHOT_LOG" | tail -1 | cut -d' ' -f3; }

case $scenario in
rec-shell)
    drv_start Meta-0 || { fail "driver"; exit 1; }
    drv key esc
    plain_desktop
    sleep 1
    touch "$OUT/marker"
    record_moving rec "200,150,480,320" 3 --clicks
    check "shotlet record exits once done" test "$RC" = 0
    check "  ... through the GNOME integration" grep -q "recording: source GNOME integration" "$SHOT_LOG"
    check "  ... without any consent dialog" no_dialog
    f=$(saved_file)
    check "  ... into the Videos folder" eval '[[ "$f" == "$HOME/Videos/shotlet-"*.mp4 ]]'
    echo "  $(grep -o "recording: saved.*" "$SHOT_LOG")"
    check "  ... H.264 at the area's size" eq "$(probe "$f" stream=codec_name,width,height,pix_fmt)" "h264,480,320,yuv420p"
    check "  ... at 30 fps" eq "$(probe "$f" stream=avg_frame_rate)" "30/1"
    d=$(duration_ms "$f")
    check "  ... about 3 s long ($d ms)" test "$d" -ge 2800 -a "$d" -le 3300
    check "  ... index at the front (faststart)" eval '[ "$(head -c 64 "$f" | grep -c moov)" = 1 ] || python3 -c "import sys; d=open(sys.argv[1],\"rb\").read(); sys.exit(0 if d.find(b\"moov\") < d.find(b\"mdat\") else 1)" "$f"'
    frame "$f" 0.2 "$OUT/f0.png"; frame "$f" 2.5 "$OUT/f1.png"
    check "  ... and the pictures change (the pointer moves)" test "$(md5sum <"$OUT/f0.png")" != "$(md5sum <"$OUT/f1.png")"
    drv pixel "$OUT/f0.png" 20 300
    check "  ... showing the desktop" near "$VAL" "$BG"
    check "the thumbnail shows the recording" any_log 10 "quick video: showing"
    check "  ... and the history keeps it" eval 'ls "$XDG_STATE_HOME"/shotlet/history/*/video >/dev/null'
    sleep 1
    shot 0 thumbnail
    drv move 0 150 790 && drv sleep 300 && drv move 0 156 789 && drv sleep 400
    shot 0 thumbnail-hover
    click 0 100 841
    sleep 0.5
    types=$(timeout 5 wl-paste -l 2>/dev/null | tr '\n' ' ')
    check "  ... whose Copy offers the file ($types)" eval '[[ "$types" == *text/uri-list* && "$types" == *video/mp4* ]]'
    check "  ... as its uri" eval 'timeout 5 wl-paste -n -t text/uri-list | tr -d "\\r" | grep -qx "file://$f"'
    check "  ... and its bytes" eval 'timeout 5 wl-paste -n -t video/mp4 | cmp -s - "$f"'
    # clicks are drawn inside the area, and recorded
    run_shotlet clicks record --region "200,150,480,320" --seconds 3 --no-countdown --clicks
    wait_log 15 "record: recording" && drv sleep 800
    click 0 440 310
    drv sleep 80
    wait_exit 20
    f=$(saved_file)
    found=0
    for t in 0.9 1.0 1.1 1.2 1.3 1.4 1.5; do
        frame "$f" "$t" "$OUT/click.png"
        drv pixel "$OUT/click.png" 240 160 && v=$VAL
        r=$((16#${v:2:2})) b=$((16#${v:6:2}))
        drv pixel "$OUT/click.png" 262 160 && w=$VAL
        rb=$((16#${w:2:2})) bb=$((16#${w:6:2}))
        if [ $((b - r)) -gt 120 ] || [ $((bb - rb)) -gt 120 ]; then found=1; break; fi
    done
    check "a click is recorded as a ripple" test "$found" = 1
    # another program asking for a screencast is refused
    gdbus call --session --dest dev.shotlet.Shell1 --object-path /dev/shotlet/Shell1 \
        --method dev.shotlet.Shell1.StartRecording "{'x': <0>, 'y': <0>, 'w': <100>, 'h': <100>}" >"$OUT/gdbus.txt" 2>&1
    check "StartRecording() from another program is refused" grep -q "AccessDenied" "$OUT/gdbus.txt"
    # stopping: shotlet record again, while one runs
    run_shotlet long record --region "100,100,320,240" --no-countdown
    wait_log 15 "record: recording"
    sleep 1
    "$BIN" record >"$OUT/again.log" 2>&1
    check "shotlet record again stops the recording" wait_exit 20
    check "  ... and keeps it" grep -q "recording: saved" "$SHOT_LOG"
    ;;
rec-pick)
    # the picker and the floating control, through the extension
    drv_start Meta-0 || { fail "driver"; exit 1; }
    drv key esc
    plain_desktop
    sleep 1
    run_shotlet pick record
    check "shotlet record asks the extension for the picker" wait_exit 10
    check "  ... which comes up" shell_wait 10 "record: picker up" 1
    sleep 1
    slow_drag 0 300 200 500 350 700 500
    sleep 0.5
    shot 0 picker
    check "  ... with the record bar under the area" eval 'drv find 0 ff453a 24 60 0 500 1600 900'
    read -r bx by _ <<<"$VAL"
    click 0 "$bx" "$by"
    check "Record starts the countdown" shell_wait 10 "record: recording" 1
    sleep 1
    shot 0 recording
    check "  ... the control sits below the area" eval 'drv find 0 ff453a 30 4 0 500 1600 900'
    drv pixel "$OUT/recording.png" 500 350
    check "  ... and not in it" near "$VAL" "$BG"
    sleep 1
    "$BIN" record --stop >"$OUT/stop.log" 2>&1
    check "shotlet record --stop ends it" shell_wait 15 "recording: saved" 1
    f=$(grep -o "recording: saved [^ ]*" "$HL_SHELL_LOG" | tail -1 | cut -d' ' -f3)
    check "  ... at the picked size" eq "$(probe "$f" stream=width,height)" "400,300"
    ;;
rec-gif)
    drv_start Meta-0 || { fail "driver"; exit 1; }
    drv key esc
    plain_desktop
    sleep 1
    record_moving gif "300,200,400,240" 3 --gif --fps 15
    f=$(saved_file)
    check "a GIF recording is written" eval '[[ "$f" == *.gif ]] && [ -s "$f" ]'
    check "  ... at the area's size" eq "$(probe "$f" stream=codec_name,width,height)" "gif,400,240"
    d=$(duration_ms "$f")
    check "  ... about 3 s long ($d ms)" test "$d" -ge 2700 -a "$d" -le 3400
    n=$(ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of csv=p=0 "$f")
    check "  ... with several distinct pictures ($n)" test "${n:-0}" -ge 5
    sz=$(stat -c %s "$f")
    echo "  GIF: $sz bytes, $n frames"
    check "  ... and small ($sz bytes)" test "$sz" -lt 400000
    frame "$f" 0.1 "$OUT/g0.png"
    drv pixel "$OUT/g0.png" 20 200
    check "  ... showing the desktop's colour" near "$VAL" "$BG"
    # pause: the paused time is not in the file
    run_shotlet pause record --region "300,200,400,240" --no-countdown --gif
    wait_log 15 "record: recording"
    sleep 1
    "$BIN" record --pause >/dev/null 2>&1
    sleep 2
    "$BIN" record --resume >/dev/null 2>&1
    sleep 1
    "$BIN" record --stop >/dev/null 2>&1
    wait_exit 20
    d=$(duration_ms "$(saved_file)")
    check "a paused recording leaves the pause out ($d ms)" test "$d" -ge 1500 -a "$d" -le 2700
    ;;
rec-trim)
    drv_start Meta-0 || { fail "driver"; exit 1; }
    drv key esc
    plain_desktop
    record_moving trim "200,150,480,320" 4
    f=$(saved_file)
    id=$(basename "$(dirname "$(ls -t "$XDG_STATE_HOME"/shotlet/history/*/video | head -1)")")
    run_shotlet trimui trim "$XDG_STATE_HOME/shotlet/history" "$id" --range 1000,2500 --export
    check "the trim window exports" wait_exit 30
    t=$(grep -o "trim: wrote [^ ]*" "$SHOT_LOG" | cut -d' ' -f3)
    d=$(duration_ms "$t")
    check "  ... a shorter file ($d ms)" test "${d:-0}" -ge 1300 -a "${d:-0}" -le 1800
    check "  ... next to the original" test "$(dirname "$t")" = "$(dirname "$f")"
    check "  ... kept with its own thumbnail" any_log 10 "quick video: showing"
    run_shotlet trimwin trim "$XDG_STATE_HOME/shotlet/history" "$id"
    wait_log 10 "trim: " && sleep 1.5
    shot 0 trim
    check "the trim window shows the filmstrip's handles" eval 'drv find 0 ffcc00 20 4'
    keys esc
    check "  ... and Esc closes it" wait_exit 5
    ;;
rec-portal)
    drv_start Meta-0 || { fail "driver"; exit 1; }
    drv key esc
    plain_desktop
    sleep 1
    run_shotlet portal record --region "200,150,480,320" --seconds 2 --no-countdown --no-control
    share_dialog 0 || fail "the share dialog"
    check "without the extension, the portal records" wait_exit 30
    check "  ... through the ScreenCast portal" grep -q "recording: source ScreenCast portal" "$SHOT_LOG"
    f=$(saved_file)
    check "  ... at the area's size" eq "$(probe "$f" stream=codec_name,width,height)" "h264,480,320"
    run_shotlet again record --region "200,150,480,320" --seconds 2 --no-countdown --no-control
    check "a second recording needs no dialog (restore token)" wait_exit 20
    check "  ... and records" grep -q "recording: saved" "$SHOT_LOG"
    check "  ... with the consent stored once" eq "$(perm_apps screencast)" "$APP_ID"
    ;;
*) skip "unknown scenario" ;;
esac
