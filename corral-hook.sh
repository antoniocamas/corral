#!/usr/bin/env bash
# Generic hook script shared by every hook-capable harness. A
# harness's config-file installer only needs to point at this same
# script, passing the state to report as $1 -- it never needs its
# own copy.
#
# Pane correlation is via $CORRAL_PANE_ID / $CORRAL_SERVER_NAME, set
# in the spawned process's environment by corral at launch time (see
# corral-harness.el's corral--do-launch). If $CORRAL_PANE_ID isn't
# set -- e.g. the tool was started outside corral -- this is a
# silent no-op.

state="$1"

if [ -z "$CORRAL_PANE_ID" ]; then
  exit 0
fi

socket_args=()
if [ -n "$CORRAL_SERVER_NAME" ]; then
  socket_args=(-s "$CORRAL_SERVER_NAME")
fi

emacsclient "${socket_args[@]}" --eval "(corral-report \"$CORRAL_PANE_ID\" \"$state\")" >/dev/null 2>&1
exit 0
