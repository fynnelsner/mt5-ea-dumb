#!/bin/bash
pkill -f webhook_server
sleep 1
nohup python3 Scripts/webhook_server.py --port 8080 > server.log 2>&1 &
echo $! > server.pid
