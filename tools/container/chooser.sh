#!/bin/sh
# xdg-desktop-portal-wlr's output chooser for the container suite: no
# dialog, it logs the call (restore-token checks count them) and names
# $HOME/chooser-output, else the first output.
echo "chooser called" >>"$HOME/chooser.log"
if [ -s "$HOME/chooser-output" ]; then
    cat "$HOME/chooser-output"
else
    echo HEADLESS-1
fi
