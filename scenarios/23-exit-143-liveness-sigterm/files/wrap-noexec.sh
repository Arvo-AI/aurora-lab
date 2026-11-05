#!/bin/sh
echo "wrapper: starting"
python3 -u /app/app.py
echo "wrapper: app exited $?"
