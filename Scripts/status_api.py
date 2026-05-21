#!/usr/bin/env python3
"""
DevyyTrades Companion API v2 — Mobile App Backend
Exposes: EA status, webhook logs, pipeline history, TV automation, system control.
"""
import json
import os
import re
import subprocess
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

CONFIG = {
    "host": "0.0.0.0",
    "port": 8090,
    "events_file": "/home/devyytrades/MT5WebhookBot/webhook_events.json",
    "pipeline_file": "/home/devyytrades/ea-server/pipeline_history.json",
    "ea_log_file": "/home/devyytrades/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Logs/DevyyTrades_EA_v2.log",
    "tv_alerts_file": "/home/devyytrades/ea-server/tv_alerts.json",
    "tv_auto_renew_file": "/home/devyytrades/ea-server/tv_auto_renew.json",
    "ea_log_dir": "/home/devyytrades/ea-server/logs",
}

# ─── Pipeline Parser ───
REJECTED_RE = re.compile(
    r'(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+\+\d{2}:\d{2}).*?\[AutoEval\]\s+(\w+)\s+(\w+)\s+bar_time=(\d+)\s+-\u003e\s+REJECTED\s+blocker=(.+)'
)
DEFERRED_RE = re.compile(
    r'(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+\+\d{2}:\d{2}).*?\[AutoEval\]\s+DEFERRED\s+(\w+)-(\d+)\s+\((\w+)\)\s+—\s+will\s+re-evaluate\s+until\s+([\d.]+)'
)
ACCEPTED_RE = re.compile(
    r'(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+\+\d{2}:\d{2}).*?\[AutoEval\]\s+(\w+)\s+(\w+)\s+bar_time=(\d+)\s+-\u003e\s+ACCEPTED'
)

def parse_iso(ts_str):
    try:
        return datetime.fromisoformat(ts_str).isoformat()
    except:
        return ts_str

def parse_pipeline():
    log_path = Path(CONFIG["ea_log_dir"]) / "ea-server.log"
    decisions = []
    if not log_path.exists():
        return decisions
    with open(log_path, 'r', errors='ignore') as f:
        for line in f:
            line = line.strip()
            if not line or '[AutoEval]' not in line:
                continue
            m = REJECTED_RE.search(line)
            if m:
                ts, symbol, direction, bar_time, blocker = m.groups()
                decisions.append({
                    "timestamp": parse_iso(ts), "symbol": symbol,
                    "direction": direction.lower(), "bar_time": int(bar_time),
                    "status": "rejected", "reason": blocker, "source": "autoeval", "raw": line,
                })
                continue
            m = DEFERRED_RE.search(line)
            if m:
                ts, symbol, bar_time, reason, until = m.groups()
                decisions.append({
                    "timestamp": parse_iso(ts), "symbol": symbol,
                    "direction": "unknown", "bar_time": int(bar_time),
                    "status": "deferred", "reason": f"Deferred ({reason}) — re-eval until {until}",
                    "source": "autoeval", "raw": line,
                })
                continue
            m = ACCEPTED_RE.search(line)
            if m:
                ts, symbol, direction, bar_time = m.groups()
                decisions.append({
                    "timestamp": parse_iso(ts), "symbol": symbol,
                    "direction": direction.lower(), "bar_time": int(bar_time),
                    "status": "accepted", "reason": "All checks passed — setup forwarded to EA",
                    "source": "autoeval", "raw": line,
                })
                continue
    decisions.reverse()
    return decisions[:500]

def save_pipeline(data):
    os.makedirs(Path(CONFIG["pipeline_file"]).parent, exist_ok=True)
    with open(CONFIG["pipeline_file"], 'w') as f:
        json.dump({
            "updated_at": datetime.now(timezone.utc).isoformat(),
            "count": len(data), "decisions": data,
        }, f, indent=2)

def load_pipeline():
    if not Path(CONFIG["pipeline_file"]).exists():
        return {"updated_at": None, "count": 0, "decisions": []}
    with open(CONFIG["pipeline_file"], 'r') as f:
        return json.load(f)

def refresh_pipeline():
    decisions = parse_pipeline()
    save_pipeline(decisions)
    return decisions

# Background refresher
def _bg_refresh():
    while True:
        try:
            refresh_pipeline()
        except Exception as e:
            print(f"[Pipeline BG] Error: {e}")
        time.sleep(30)

threading.Thread(target=_bg_refresh, daemon=True).start()

# ─── Helpers ───
def now_iso():
    return datetime.now(timezone.utc).isoformat()

def get_mt5_status():
    try:
        mt5 = subprocess.run(['pgrep', '-f', 'terminal64.exe'], capture_output=True, text=True)
        wine = subprocess.run(['pgrep', '-f', 'wineserver'], capture_output=True, text=True)
        return {"mt5_running": mt5.returncode == 0, "wine_running": wine.returncode == 0, "timestamp": now_iso()}
    except Exception as e:
        return {"error": str(e)}

def get_recent_webhooks(limit=20):
    try:
        with open(CONFIG["events_file"], 'r') as f:
            data = json.load(f)
        return data.get("events", [])[:limit]
    except Exception:
        return []

def get_ea_logs(limit=50):
    try:
        log_path = CONFIG["ea_log_file"]
        if not Path(log_path).exists():
            return []
        with open(log_path, 'r', errors='ignore') as f:
            lines = f.readlines()
        return [line.strip() for line in lines[-limit:] if line.strip()]
    except Exception:
        return []

def get_account_data():
    try:
        account_file = "/home/devyytrades/ea-server/feeds/mt5_account.json"
        if not Path(account_file).exists():
            return None
        with open(account_file, 'r', errors='ignore') as f:
            return json.load(f)
    except Exception as e:
        return {"error": str(e)}

def get_tv_alerts():
    try:
        if not Path(CONFIG["tv_alerts_file"]).exists():
            return []
        with open(CONFIG["tv_alerts_file"], 'r') as f:
            return json.load(f)
    except Exception:
        return []

def get_tv_auto_renew_status():
    try:
        if not Path(CONFIG["tv_auto_renew_file"]).exists():
            return {"enabled": False, "last_run": None, "alerts_refreshed": 0}
        with open(CONFIG["tv_auto_renew_file"], 'r') as f:
            return json.load(f)
    except Exception:
        return {"enabled": False, "last_run": None, "alerts_refreshed": 0}

# ─── HTTP Handler ───
class APIHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS, PATCH, DELETE')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()

    def _send_json(self, code, data):
        self.send_response(code)
        self.send_header('Content-type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(json.dumps(data, indent=2).encode())

    def _read_body(self):
        length = int(self.headers.get('Content-Length', 0))
        if length:
            return json.loads(self.rfile.read(length).decode())
        return {}

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        query = parse_qs(parsed.query)

        if path == '/api/status':
            self._send_json(200, {
                "system": get_mt5_status(),
                "account": {"status": "pending", "message": "Account sync coming in v2"},
                "webhooks_last_24h": len(get_recent_webhooks(1000)),
            })
        elif path == '/api/webhooks':
            limit = int(query.get('limit', ['20'])[0])
            symbol = query.get('symbol', [''])[0].upper()
            events = get_recent_webhooks(limit * 5)
            if symbol:
                events = [e for e in events if symbol in str(e).upper()]
            self._send_json(200, {"events": events[:limit]})
        elif path == '/api/logs':
            limit = int(query.get('limit', ['50'])[0])
            self._send_json(200, {"logs": get_ea_logs(limit)})
        elif path == '/api/health':
            self._send_json(200, {"status": "ok"})
        elif path == '/api/pipeline':
            data = load_pipeline()
            status_filter = query.get('status', [''])[0].lower()
            symbol_filter = query.get('symbol', [''])[0].upper()
            decisions = data.get("decisions", [])
            if status_filter:
                decisions = [d for d in decisions if d.get("status") == status_filter]
            if symbol_filter:
                decisions = [d for d in decisions if d.get("symbol", '').upper() == symbol_filter]
            self._send_json(200, {
                "updated_at": data.get("updated_at"),
                "count": len(decisions),
                "decisions": decisions,
            })
        elif path == '/api/account':
            data = get_account_data()
            if data is None:
                self._send_json(503, {'error': 'MT5 account data not available — ensure EA is running on chart with AccountHistoryExporter enabled'})
            else:
                self._send_json(200, data)
        elif path == '/api/tv/alerts':
            self._send_json(200, {"alerts": get_tv_alerts()})
        elif path == '/api/tv/status':
            self._send_json(200, get_tv_auto_renew_status())
        else:
            self._send_json(404, {"error": "Not found", "path": path})

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path
        body = self._read_body() if int(self.headers.get('Content-Length', 0)) else {}

        if path == '/api/restart':
            threading.Thread(target=self._queue_restart, daemon=True).start()
            self._send_json(200, {"message": "Restart queued — check status in 30s"})
        elif path == '/api/tv/refresh-alerts':
            result = self._queue_tv_refresh()
            self._send_json(200, result)
        elif path == '/api/tv/auto-renew':
            enabled = body.get('enabled', False)
            days_ahead = body.get('days_ahead', 30)
            self._save_tv_auto_renew(enabled, days_ahead)
            self._send_json(200, {
                "message": f"Auto-renew {'enabled' if enabled else 'disabled'}",
                "days_ahead": days_ahead,
            })
        elif path == '/api/pipeline/refresh':
            decisions = refresh_pipeline()
            self._send_json(200, {"refreshed": len(decisions), "message": "Pipeline refreshed"})
        else:
            self._send_json(404, {"error": "Not found"})

    def _queue_restart(self):
        try:
            subprocess.run(['bash', '-c', 'sleep 2; sudo systemctl restart companion-api'], check=False)
        except Exception as e:
            print(f"Restart error: {e}")

    def _queue_tv_refresh(self):
        status = get_tv_auto_renew_status()
        status["last_run"] = now_iso()
        status["alerts_refreshed"] = status.get("alerts_refreshed", 0) + 1
        self._save_tv_auto_renew(status.get("enabled", False), status.get("days_ahead", 30), status)
        return {"refreshed": 0, "message": "TradingView automation stub — implement Playwright", "status": status}

    def _save_tv_auto_renew(self, enabled, days_ahead, extra=None):
        data = {"enabled": enabled, "days_ahead": days_ahead, "updated_at": now_iso()}
        if extra:
            data.update({k: v for k, v in extra.items() if k not in data})
        try:
            os.makedirs(Path(CONFIG["tv_auto_renew_file"]).parent, exist_ok=True)
            with open(CONFIG["tv_auto_renew_file"], 'w') as f:
                json.dump(data, f, indent=2)
        except Exception as e:
            print(f"Save error: {e}")

def run():
    # Initial pipeline parse on startup
    try:
        refresh_pipeline()
        print("[Pipeline] Initial parse complete")
    except Exception as e:
        print(f"[Pipeline] Initial parse error: {e}")
    
    server = HTTPServer((CONFIG["host"], CONFIG["port"]), APIHandler)
    print(f"Companion API v2 running on {CONFIG['host']}:{CONFIG['port']}")
    server.serve_forever()

if __name__ == '__main__':
    run()
