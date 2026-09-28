#!/bin/sh
# copied.sh <socket> <pane> <selection>: run by tmux/tmux.conf as the copy-pipe
# command of a mouse selection, with the copied text on stdin. Records how many
# characters were copied, keyed by the selection's coordinates, so the copy-mode
# indicator shows the count only while that same selection is on screen.
# wc -m counts characters in the server's locale, bytes in a C locale.
n=$(wc -m | tr -d ' ')
exec tmux -S "$1" set -p -t "$2" @copied "$3 $n"
