#!/bin/sh
trap 'echo "wrapper: trap ran"; exit 143' TERM
echo "wrapper: starting"
python3 -u /app/app.py
