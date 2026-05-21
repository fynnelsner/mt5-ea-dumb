#!/bin/bash

# DevyyTrades MT5 Webhook Server Startup Script
# For Linux/Mac systems

echo "=========================================="
echo "DevyyTrades MT5 Webhook Server"
echo "=========================================="
echo ""

# Check if Python is installed
if ! command -v python3 &> /dev/null; then
    echo "Python 3 is not installed"
    echo "Please install Python from https://python.org"
    exit 1
fi

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Check if dependencies are installed
echo "Checking dependencies..."
if ! python3 -c "import requests" 2>/dev/null; then
    echo "Installing dependencies..."
    pip3 install -r requirements.txt
fi

# Get local IP for TradingView configuration
LOCAL_IP=$(ifconfig | grep "inet " | grep -v 127.0.0.1 | awk '{print $2}' | head -n 1)
if [ -z "$LOCAL_IP" ]; then
    LOCAL_IP=$(hostname -I | awk '{print $1}')
fi

echo ""
echo "Your local IP: $LOCAL_IP"
echo "Use this in TradingView webhook URL: http://$LOCAL_IP:8080"
echo ""

# Start the server
echo "Starting Webhook Server..."
echo "Default port: 8080"
echo ""
echo "Usage: ./start_server.sh [--quiet]"
echo "  --quiet: Log to file only (prevents logs covering terminal input)"
echo ""
echo "Press Ctrl+C to stop"
echo ""

# Check for --quiet flag
if [[ "$*" == *"--quiet"* ]] || [[ "$*" == *"-q"* ]]; then
    QUIET_FLAG="--quiet"
    echo "Quiet mode enabled - logs written to webhook_server.log only"
echo ""
fi

python3 webhook_server.py --port 8080 $QUIET_FLAG "$@"