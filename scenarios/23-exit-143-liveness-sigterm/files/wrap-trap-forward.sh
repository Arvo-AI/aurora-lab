#!/bin/sh
trap 'echo "wrapper: forwarding"; kill -TERM "$child"' TERM
echo "wrapper: starting"
python3 -u /app/app.py &
child=$!
wait "$child"
wait "$child"
exit $?
