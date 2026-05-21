@echo off
echo ==========================================
echo DevyyTrades MT5 Webhook Server
echo ==========================================
echo.

:: Check if Python is installed
python --version >nul 2>&1
if errorlevel 1 (
    echo Python is not installed or not in PATH
    echo Please install Python from https://python.org
    pause
    exit /b 1
)

:: Change to script directory
cd /d "%~dp0"

:: Check if dependencies are installed
echo Checking dependencies...
pip show requests >nul 2>&1
if errorlevel 1 (
    echo Installing dependencies...
    pip install -r requirements.txt
)

:: Start the server
echo.
echo Starting Webhook Server...
echo Default port: 8080
echo.
echo Press Ctrl+C to stop
echo.

python webhook_server.py --port 8080

pause