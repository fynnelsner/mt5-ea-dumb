#!/usr/bin/env python3
"""
DevyyTrades MT5 Webhook Server
Receives webhook signals from TradingView, shows a simple dashboard,
and writes normalized state/signals for later MT5 EA consumption.
"""

import json
import os
import time
import logging
import hmac
import hashlib
from copy import deepcopy
from datetime import datetime
from pathlib import Path
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import parse_qs, urlparse

CONFIG = {
    "host": "0.0.0.0",
    "port": 8084,
    "mt5_files_path": str(Path.home() / "AppData" / "Roaming" / "MetaQuotes" / "Terminal" / "Common" / "Files"),
    "auth_token": "",
    "log_file": "webhook_server.log",
    "signal_file": "DevyyTrades_Signals.json",
    "state_file": "webhook_state.json",
    "events_file": "webhook_events.json",  # NEW: Persistent storage for events
    "allowed_ips": [],
    "max_signals_per_minute": 120,
    "max_events": 0,  # 0 means unlimited
}

logger = logging.getLogger(__name__)


def setup_logging(quiet=False):
    formatter = logging.Formatter('%(asctime)s - %(levelname)s - %(message)s')
    logger.handlers = []

    file_handler = logging.FileHandler(CONFIG["log_file"])
    file_handler.setFormatter(formatter)
    logger.addHandler(file_handler)

    if not quiet:
        stream_handler = logging.StreamHandler()
        stream_handler.setFormatter(formatter)
        logger.addHandler(stream_handler)
    else:
        print(f"Logging to file only: {CONFIG['log_file']} (quiet mode)")

    logger.setLevel(logging.INFO)


class SignalState:
    def __init__(self):
        self.last_signals = {}
        self.symbols = {}
        self.events = []
        self._load()  # Load persisted data on startup

    def _load(self):
        """Load events and state from disk on startup"""
        events_path = Path(CONFIG["events_file"])
        if events_path.exists():
            try:
                with open(events_path, 'r') as f:
                    data = json.load(f)
                    self.events = data.get('events', [])
                    self.symbols = data.get('symbols', {})
                    self.last_signals = data.get('last_signals', {})
                logger.info(f"Loaded {len(self.events)} events from {CONFIG['events_file']}")
            except Exception as e:
                logger.error(f"Failed to load events: {e}")

    def _save(self):
        """Persist events and state to disk"""
        try:
            with open(CONFIG["events_file"], 'w') as f:
                json.dump({
                    'events': self.events,
                    'symbols': self.symbols,
                    'last_signals': self.last_signals,
                    'saved_at': datetime.utcnow().isoformat() + 'Z'
                }, f, indent=2)
        except Exception as e:
            logger.error(f"Failed to save events: {e}")

    def _ensure_symbol(self, symbol):
        if symbol not in self.symbols:
            self.symbols[symbol] = {
                "wickless": {
                    "trend": None,
                    "last_structure": None,
                    "last_signal": None,
                },
                "fvg": {},
                "news": {},
                "updated_at": None,
            }
        return self.symbols[symbol]

    def add_event(self, event):
        event = deepcopy(event)
        event["received_at"] = datetime.utcnow().isoformat() + "Z"
        self.events.insert(0, event)
        # Only trim if max_events is set (non-zero)
        if CONFIG["max_events"] > 0:
            self.events = self.events[:CONFIG["max_events"]]
        self._save()  # Persist to disk

    def process_payload(self, data):
        symbol = data.get("symbol", "")
        if not symbol:
            raise ValueError("Missing symbol")

        if data.get("source") == "wickless":
            event_type = data.get("event", "")
            body = data.get("data", {}) if isinstance(data.get("data", {}), dict) else {}
            symbol_state = self._ensure_symbol(symbol)

            if event_type == "structure_update":
                symbol_state["wickless"]["trend"] = body.get("direction")
                symbol_state["wickless"]["last_structure"] = {
                    "event": event_type,
                    "direction": body.get("direction"),
                    "break_type": body.get("break_type"),
                    "break_level": body.get("break_level"),
                    "latest_structure_high": body.get("latest_structure_high"),
                    "latest_structure_low": body.get("latest_structure_low"),
                    "bar_time": data.get("bar_time"),
                    "timeframe": data.get("timeframe"),
                }
                symbol_state["updated_at"] = datetime.utcnow().isoformat() + "Z"
                self.add_event(data)
                return {
                    "indicator": "Wickless",
                    "signalType": f"{body.get('break_type', '')}_{body.get('direction', '').upper()}",
                    "symbol": symbol,
                    "price": body.get("break_level", 0),
                    "high": body.get("candle_high", 0),
                    "low": body.get("candle_low", 0),
                    "swingHigh": body.get("latest_structure_high", 0),
                    "swingLow": body.get("latest_structure_low", 0),
                    "timeframe": data.get("timeframe", "15"),
                    "raw": data,
                }

            if event_type == "wickless_signal":
                # Support both old (direction) and new (candle_direction/trend_direction) formats
                candle_dir = body.get("candle_direction") or body.get("direction", "")
                trend_dir = body.get("trend_direction") or symbol_state["wickless"].get("trend", "neutral")
                symbol_state["wickless"]["last_signal"] = {
                    "event": event_type,
                    "candle_direction": candle_dir,
                    "trend_direction": trend_dir,
                    "entry_anchor": body.get("entry_anchor"),
                    "latest_structure_high": body.get("latest_structure_high"),
                    "latest_structure_low": body.get("latest_structure_low"),
                    "bar_time": data.get("bar_time"),
                    "timeframe": data.get("timeframe"),
                }
                symbol_state["wickless"]["trend"] = trend_dir  # Update current trend
                symbol_state["updated_at"] = datetime.utcnow().isoformat() + "Z"
                self.add_event(data)
                return {
                    "indicator": "Wickless",
                    "signalType": f"NOWICK_{candle_dir.upper()}",
                    "symbol": symbol,
                    "price": body.get("entry_anchor", 0),
                    "high": body.get("candle_high", 0),
                    "low": body.get("candle_low", 0),
                    "swingHigh": body.get("latest_structure_high", 0),
                    "swingLow": body.get("latest_structure_low", 0),
                    "timeframe": data.get("timeframe", "15"),
                    "raw": data,
                }

            raise ValueError(f"Unsupported wickless event: {event_type}")

        if data.get("event") == "fvg_snapshot":
            """Handle FVG batch snapshot — replaces per-FVG events with one sync per bar."""
            symbol_state = self._ensure_symbol(symbol)
            fvgs = data.get("fvgs", [])
            symbol_state["fvg"] = {
                "active_zones": fvgs,
                "count": data.get("count", len(fvgs)),
                "chart_timeframe": data.get("chart_timeframe", ""),
                "bar_time": data.get("bar_time"),
                "bar_index": data.get("bar_index"),
                "updated_at": datetime.utcnow().isoformat() + "Z",
            }
            self.add_event(data)
            return {
                "indicator": "FVG",
                "signalType": "FVG_SNAPSHOT",
                "symbol": symbol,
                "timeframe": data.get("chart_timeframe", "15"),
                "count": len(fvgs),
                "raw": data,
            }

        # Handle generic/unknown webhook payloads (accept anything)
        indicator = data.get("indicator", "")
        if not indicator and data.get("test"):
            # Handle test webhooks
            self.add_event(data)
            return {"indicator": "Test", "signalType": "TEST", "symbol": symbol or "UNKNOWN", "raw": data}
        if not indicator:
            raise ValueError("Missing required fields: source/event or indicator")

        self.add_event(data)
        symbol_state = self._ensure_symbol(symbol)
        symbol_state["updated_at"] = datetime.utcnow().isoformat() + "Z"

        if indicator == "Wickless":
            signal_type = data.get("signalType", "")
            if "BULLISH" in signal_type:
                symbol_state["wickless"]["trend"] = "bullish"
            elif "BEARISH" in signal_type:
                symbol_state["wickless"]["trend"] = "bearish"

            if signal_type.startswith("NOWICK"):
                symbol_state["wickless"]["last_signal"] = {
                    "event": "legacy_wickless_signal",
                    "direction": "bullish" if "BULLISH" in signal_type else "bearish",
                    "entry_anchor": data.get("price"),
                    "latest_structure_high": data.get("swingHigh"),
                    "latest_structure_low": data.get("swingLow"),
                    "bar_time": data.get("timestamp"),
                    "timeframe": data.get("timeframe"),
                }
            else:
                symbol_state["wickless"]["last_structure"] = {
                    "event": "legacy_structure_update",
                    "direction": "bullish" if "BULLISH" in signal_type else "bearish",
                    "break_type": signal_type.split("_")[0] if "_" in signal_type else signal_type,
                    "break_level": data.get("price"),
                    "latest_structure_high": data.get("swingHigh"),
                    "latest_structure_low": data.get("swingLow"),
                    "bar_time": data.get("timestamp"),
                    "timeframe": data.get("timeframe"),
                }

        return data

    def snapshot(self):
        return {
            "symbols": self.symbols,
            "events": self.events,
            "updated_at": datetime.utcnow().isoformat() + "Z",
        }


state = SignalState()


def save_state():
    try:
        with open(CONFIG["state_file"], "w", encoding="utf-8") as f:
            json.dump(state.snapshot(), f, indent=2)
    except Exception as e:
        logger.error(f"Failed to save state: {e}")


def render_dashboard():
    snapshot = state.snapshot()
    events_json = json.dumps(snapshot["events"], ensure_ascii=False)
    symbols_json = json.dumps(snapshot["symbols"], ensure_ascii=False)

    html = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>DevyyTrades Webhook Monitor</title>
  <style>
    :root {
      --bg: #0b1020; --panel: rgba(17, 24, 39, 0.82); --panel-2: rgba(15, 23, 42, 0.92);
      --border: rgba(255,255,255,0.06); --text: #f8fafc; --muted: #94a3b8;
      --green: #22c55e; --red: #ef4444; --amber: #f59e0b; --accent: #7c3aed; --blue: #38bdf8;
    }
    * { box-sizing: border-box; margin: 0; }
    body {
      font-family: Inter,ui-sans-serif,system-ui,-apple-system,sans-serif;
      color: var(--text); background: linear-gradient(180deg,#050816,#0b1020); min-height: 100vh;
    }
    .container { max-width: 1200px; margin: 0 auto; padding: 20px; }
    .hero {
      display:flex; justify-content:space-between; align-items:end; gap:16px; margin-bottom:20px;
      padding: 22px 24px; border: 1px solid var(--border); border-radius: 18px;
      background: linear-gradient(135deg, rgba(124,58,237,0.14), rgba(15,23,42,0.96));
      backdrop-filter: blur(12px); box-shadow: 0 8px 32px rgba(0,0,0,0.25);
    }
    .title { font-size: 28px; font-weight: 700; margin-bottom: 4px; }
    .subtitle { color: var(--muted); font-size: 14px; }
    .pill {
      display: inline-flex; align-items: center; gap: 8px; padding: 10px 14px; border-radius: 999px;
      background: rgba(34,197,94,0.12); border: 1px solid rgba(34,197,94,0.25); color: #dcfce7; font-weight: 600; font-size: 13px;
    }
    .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--green); box-shadow: 0 0 12px var(--green); }
    .panel { border: 1px solid var(--border); border-radius: 16px; background: var(--panel); backdrop-filter: blur(10px); overflow: hidden; }
    .panel-body { padding: 0; }
    .log-table { width: 100%; border-collapse: separate; border-spacing: 0 6px; padding: 0 12px 12px; }
    .log-table thead { position: sticky; top: 0; z-index: 10; }
    .log-table th {
      text-align: left; padding: 12px 16px 10px; font-size: 11px; font-weight: 600; color: var(--muted);
      text-transform: uppercase; letter-spacing: 0.06em; background: rgba(15,23,42,0.95);
      border-bottom: 1px solid var(--border); cursor: pointer; user-select: none; transition: color 0.2s;
    }
    .log-table th:hover { color: var(--text); }
    .log-table th .sort { margin-left: 4px; opacity: 0.5; }
    .log-table th.sort-asc .sort { opacity: 1; content: '↑'; }
    .log-table th.sort-desc .sort { opacity: 1; content: '↓'; }
    .log-row { background: var(--panel-2); border-radius: 14px; overflow: hidden; transition: all 0.15s; cursor: pointer; box-shadow: 0 2px 8px rgba(0,0,0,0.15); }
    .log-row:hover { background: rgba(255,255,255,0.06); transform: translateY(-1px); box-shadow: 0 4px 14px rgba(0,0,0,0.25); }
    .log-row.active { background: rgba(124,58,237,0.12); border: 1px solid rgba(124,58,237,0.25); }
    .log-row td { padding: 10px 16px; vertical-align: middle; border-top: 1px solid var(--border); border-bottom: 1px solid var(--border); }
    .log-row td:first-child { border-left: 1px solid var(--border); border-radius: 14px 0 0 14px; }
    .log-row td:last-child { border-right: 1px solid var(--border); border-radius: 0 14px 14px 0; }
    .td-symbol { font-weight: 700; font-size: 14px; white-space: nowrap; }
    .td-type { font-size: 12px; color: var(--muted); }
    .td-time { font-size: 12px; color: var(--muted); font-family: ui-monospace,SFMono-Regular,Menlo,monospace; }
    .td-badge .tag {
      display: inline-flex; align-items: center; gap: 6px; border-radius: 6px; padding: 4px 8px;
      font-size: 11px; font-weight: 700; letter-spacing: 0.02em; text-transform: uppercase; white-space: nowrap;
    }
    .tag.green { background: rgba(34,197,94,0.12); color: #bbf7d0; border: 1px solid rgba(34,197,94,0.2); }
    .tag.red { background: rgba(239,68,68,0.12); color: #fecaca; border: 1px solid rgba(239,68,68,0.2); }
    .tag-amber { background: rgba(245,158,11,0.12); color: #fde68a; border: 1px solid rgba(245,158,11,0.2); }
    .tag.blue { background: rgba(56,189,248,0.12); color: #bae6fd; border: 1px solid rgba(56,189,248,0.2); }
    .td-expand { text-align: right; }
    .expand-btn {
      background: rgba(255,255,255,0.05); border: 1px solid var(--border); border-radius: 6px;
      color: var(--muted); font-size: 12px; padding: 4px 8px; cursor: pointer; transition: all 0.2s;
    }
    .expand-btn:hover { color: var(--text); background: rgba(255,255,255,0.08); }
    .raw-row { display: none; }
    .raw-row.open { display: table-row; }
    .raw-row td { padding: 0 0 12px 0; border: none; }
    .raw-row td:first-child { border-left: none; border-radius: 0; }
    .raw-row td:last-child { border-right: none; border-radius: 0; }
    .raw-inner {
      background: rgba(12,16,30,0.92); border: 1px solid var(--border); border-radius: 14px;
      padding: 16px; overflow: auto; margin: 0 16px;
      box-shadow: inset 0 2px 8px rgba(0,0,0,0.2);
    }
    .raw-inner pre {
      margin: 0; white-space: pre-wrap; word-break: break-word; font-size: 11px;
      color: #cbd5e1; font-family: ui-monospace,SFMono-Regular,Menlo,monospace; line-height: 1.6;
    }

    .filters {
      display: flex; gap: 12px; flex-wrap: wrap; align-items: center;
      padding: 14px 16px; border-bottom: 1px solid var(--border); background: rgba(15,23,42,0.6);
    }
    .filter-group { display: flex; flex-direction: column; gap: 4px; }
    .filter-label { font-size: 11px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.04em; font-weight: 600; }
    .filter-input {
      background: var(--panel-2); border: 1px solid var(--border); border-radius: 6px;
      padding: 5px 10px; color: var(--text); font-size: 13px; outline: none;
    }
    .filter-input:focus { border-color: var(--accent); }
    .filter-select { background: var(--panel-2); border: 1px solid var(--border); border-radius: 6px;
      padding: 5px 10px; color: var(--text); font-size: 13px; outline: none; cursor: pointer; }
    .btn {
      display: inline-flex; align-items: center; gap: 6px; padding: 6px 12px; border-radius: 6px;
      background: rgba(255,255,255,0.05); border: 1px solid var(--border); color: var(--text); font-size: 13px;
      font-weight: 600; cursor: pointer; transition: all 0.2s;
    }
    .btn:hover { background: rgba(255,255,255,0.08); border-color: rgba(255,255,255,0.12); }
    .btn.red { background: rgba(239,68,68,0.12); border-color: rgba(239,68,68,0.2); color: #fecaca; }
    .btn.red:hover { background: rgba(239,68,68,0.2); }
    .btn.primary { background: var(--accent); border-color: var(--accent); color: white; }
    .btn.primary:hover { background: #6d28d9; }
    .counts { display: flex; gap: 12px; flex-wrap: wrap; align-items: center; margin-bottom: 12px; }
    .count { font-size: 13px; color: var(--muted); }
    .count strong { color: var(--text); font-weight: 700; }

    /* Responsive */
    @media (max-width: 768px) {
      .hero { flex-direction: column; align-items: flex-start; gap: 14px; }
      .log-table th, .log-row td { padding: 10px 8px; font-size: 12px; }
      .log-row td:nth-child(3) { display: none; }
      .log-table th:nth-child(3) { display: none; }
      .filters { flex-direction: column; align-items: stretch; }
      .filter-group { width: 100%; }
      .filter-input, .filter-select { width: 100%; }
    }
  </style>
</head>
<body>
  <div class="container">
    <div class="hero">
      <div>
        <div class="title">DevyyTrades Webhook Monitor</div>
        <p class="subtitle">TradingView signal intake — Wickless, FVG, News</p>
      </div>
      <div class="pill"><span class="dot"></span> Live</div>
    </div>

    <div class="counts" id="counts"></div>

    <div class="panel">
      <div class="filters">
        <div class="filter-group">
          <span class="filter-label">Symbol</span>
          <input type="text" id="symbol-filter" class="filter-input" placeholder="e.g. GBPUSD..." oninput="applyFilters()">
        </div>
        <div class="filter-group">
          <span class="filter-label">Type</span>
          <select id="type-filter" class="filter-select" onchange="applyFilters()">
            <option value="all">All</option>
            <option value="real">Real</option>
            <option value="test">Test</option>
          </select>
        </div>
        <div class="filter-group">
          <span class="filter-label">Direction</span>
          <select id="direction-filter" class="filter-select" onchange="applyFilters()">
            <option value="all">All</option>
            <option value="bullish">Bullish</option>
            <option value="bearish">Bearish</option>
            <option value="neutral">Neutral</option>
          </select>
        </div>
        <div class="filter-group">
          <span class="filter-label">Timeframe</span>
          <select id="tf-filter" class="filter-select" onchange="applyFilters()">
            <option value="all">All</option>
            <option value="1">1</option>
            <option value="5">5</option>
            <option value="15">15</option>
            <option value="60">60</option>
            <option value="240">240</option>
            <option value="D">D</option>
            <option value="W">W</option>
          </select>
        </div>
        <button class="btn red" onclick="clearFilters()">Clear</button>
        <button class="btn primary" onclick="location.reload()">Refresh</button>
      </div>

      <div class="panel-body">
        <table class="log-table">
          <thead>
            <tr>
              <th onclick="sortBy('time')" data-sort="time">Time <span class="sort" id="s-time"></span></th>
              <th onclick="sortBy('symbol')" data-sort="symbol">Pair <span class="sort" id="s-symbol"></span></th>
              <th onclick="sortBy('direction')" data-sort="direction">Direction <span class="sort" id="s-direction"></span></th>
              <th onclick="sortBy('type')" data-sort="type">Type <span class="sort" id="s-type"></span></th>
              <th style="text-align:right;">JSON</th>
            </tr>
          </thead>
          <tbody id="log-body"></tbody>
        </table>
      </div>
    </div>

    <div style="margin-top: 14px; color: var(--muted); font-size: 12px; text-align: center;">
      webhook.devyytrades.com · Manual refresh · {events.length} events
    </div>
  </div>

  <script>
    const events = __EVENTS_JSON__;

    // Normalize legacy payloads: add candle_type and trend_direction if missing
    events.forEach(e => {
      const body = e.data || e;
      if (body && !body.candle_type && body.direction) body.candle_type = body.direction;
      if (body && !body.trend_direction && body.direction) body.trend_direction = body.direction;
    });

    let sortField = 'time', sortDir = 'desc';
    let filters = { symbol: '', type: 'all', direction: 'all', tf: 'all' };

    function fmtDirection(dir) {
      if (!dir) return 'neutral';
      return dir.toLowerCase();
    }
    function dirClass(dir) {
      const d = fmtDirection(dir);
      return d === 'bullish' ? 'green' : d === 'bearish' ? 'red' : 'blue';
    }
    function isTest(e) {
      return e.hasOwnProperty('test') || e.event === 'test';
    }
    function getBody(e) {
      return e.data || e;
    }
    function getTime(e) {
      return e.received_at || e.bar_time || '';
    }
    function getSymbol(e) {
      const b = getBody(e);
      return e.symbol || b.symbol || '—';
    }
    function getDirection(e) {
      const b = getBody(e);
      if (b.trend_direction) return b.trend_direction;
      if (b.direction) return b.direction;
      return 'neutral';
    }
    function getCandleType(e) {
      const b = getBody(e);
      return b.candle_type || b.direction || '—';
    }
    function getTF(e) {
      return e.timeframe || getBody(e).timeframe || '?';
    }

    function applyFilters() {
      filters.symbol = document.getElementById('symbol-filter').value.toUpperCase();
      filters.type = document.getElementById('type-filter').value;
      filters.direction = document.getElementById('direction-filter').value;
      filters.tf = document.getElementById('tf-filter').value;
      render();
    }

    function sortBy(field) {
      if (sortField === field) sortDir = sortDir === 'asc' ? 'desc' : 'asc';
      else { sortField = field; sortDir = 'asc'; }
      render();
    }

    function clearFilters() {
      document.getElementById('symbol-filter').value = '';
      document.getElementById('type-filter').value = 'all';
      document.getElementById('direction-filter').value = 'all';
      document.getElementById('tf-filter').value = 'all';
      applyFilters();
    }

    function toggleRaw(id) {
      const el = document.getElementById('raw-' + id);
      const btn = document.getElementById('btn-' + id);
      if (el.classList.contains('open')) {
        el.classList.remove('open');
        btn.textContent = 'Show';
      } else {
        el.classList.add('open');
        btn.textContent = 'Hide';
      }
    }

    function render() {
      // Filter
      let filtered = events.filter(e => {
        const sym = getSymbol(e).toUpperCase();
        if (filters.symbol && !sym.includes(filters.symbol)) return false;
        if (filters.type === 'test' && !isTest(e)) return false;
        if (filters.type === 'real' && isTest(e)) return false;
        const dir = fmtDirection(getDirection(e));
        if (filters.direction !== 'all' && dir !== filters.direction) return false;
        const tf = String(getTF(e));
        if (filters.tf !== 'all' && tf !== filters.tf) return false;
        return true;
      });

      // Sort
      filtered.sort((a, b) => {
        let va, vb;
        if (sortField === 'time') {
          va = getTime(a); vb = getTime(b);
        } else if (sortField === 'symbol') {
          va = getSymbol(a); vb = getSymbol(b);
        } else if (sortField === 'direction') {
          va = getDirection(a); vb = getDirection(b);
        } else {
          va = isTest(a) ? 'test' : 'real'; vb = isTest(b) ? 'test' : 'real';
        }
        if (va < vb) return sortDir === 'asc' ? -1 : 1;
        if (va > vb) return sortDir === 'asc' ? 1 : -1;
        return 0;
      });

      // Update sort indicators
      document.querySelectorAll('th[data-sort]').forEach(th => {
        th.classList.remove('sort-asc', 'sort-desc');
        const field = th.getAttribute('data-sort');
        const span = th.querySelector('.sort');
        span.textContent = '';
        if (field === sortField) {
          th.classList.add(sortDir === 'asc' ? 'sort-asc' : 'sort-desc');
          span.textContent = sortDir === 'asc' ? '↑' : '↓';
        }
      });

      // Render rows
      const tbody = document.getElementById('log-body');
      if (!filtered.length) {
        tbody.innerHTML = '<tr><td colspan="5" style="padding:28px;text-align:center;color:var(--muted);">No events found.</td></tr>';
      } else {
        let out = '';
        filtered.forEach((e, idx) => {
          const id = String(idx);
          const sym = getSymbol(e);
          const body = getBody(e);
          const evtType = isTest(e) ? 'test' : (body.event || e.event || 'signal');
          const tf = getTF(e);
          const dir = getDirection(e);
          const candle = getCandleType(e);
          const time = getTime(e);
          let displayTime = time;
          if (typeof time === 'string' && time.includes('T')) {
            const d = new Date(time);
            displayTime = d.toLocaleTimeString('en-US',{hour:'2-digit',minute:'2-digit',second:'2-digit',hour12:false}) + ' · ' + d.toLocaleDateString('en-US',{month:'short',day:'numeric'});
          }
          const raw = JSON.stringify(e, null, 2);

          // Trend badge (with candle type in parens if different)
          let dirLabel = dir ? dir.toUpperCase().substring(0,4) : 'NEUT';
          if (candle && candle.toLowerCase() !== fmtDirection(dir))
            dirLabel += '/' + candle.toUpperCase().substring(0,4);

          out += `
            <tr class="log-row" onclick="toggleRaw('${id}')">
              <td class="td-time">${displayTime}</td>
              <td>
                <div class="td-symbol">${sym}</div>
                <div class="td-type">${evtType} · ${tf}</div>
              </td>
              <td class="td-badge">
                <span class="tag ${dirClass(dir)}">${dirLabel}</span>
              </td>
              <td class="td-badge">
                <span class="tag ${isTest(e) ? 'tag-amber' : 'blue'}">${isTest(e) ? 'TEST' : 'LIVE'}</span>
              </td>
              <td class="td-expand">
                <button class="expand-btn" id="btn-${id}" onclick="event.stopPropagation();toggleRaw('${id}')">Show</button>
              </td>
            </tr>
            <tr class="raw-row" id="raw-${id}">
              <td colspan="5">
                <div class="raw-inner">
                  <pre>${raw}</pre>
                </div>
              </td>
            </tr>`;
        });
        tbody.innerHTML = out;
      }

      // Update counts
      const total = events.length;
      const showing = filtered.length;
      document.getElementById('counts').innerHTML = `
        <span class="count">Events: <strong>${total}</strong></span>
        <span class="count">Showing: <strong>${showing}</strong></span>
        ${filters.symbol ? '<span class="count">Filter: <strong>' + filters.symbol + '</strong></span>' : ''}
      `;
    }

    // Init
    render();
  </script>
</body>
</html>"""

    html = html.replace("__EVENTS_JSON__", events_json)
    html = html.replace("__SYMBOLS_JSON__", symbols_json)
    return html

class WebhookHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        logger.info(f"{self.address_string()} - {fmt % args}")

    def do_GET(self):
        parsed = urlparse(self.path)

        if parsed.path in ["/health", "/healthz"]:
            self._send_json(200, {"status": "ok", "service": "DevyyTrades Webhook"})
            return

        if parsed.path in ["/state", "/api/state"]:
            self._send_json(200, state.snapshot())
            return

        if parsed.path == "/events":
            self._send_json(200, {"events": state.events})
            return

        self.send_response(200)
        self.send_header('Content-type', 'text/html; charset=utf-8')
        self.end_headers()
        self.wfile.write(render_dashboard().encode('utf-8'))

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path not in ["/", "/webhook", "/fvg"]:
            self._send_error(404, "Not found")
            return

        try:
            client_ip = self.client_address[0]
            if not self._check_rate_limit(client_ip):
                self._send_error(429, "Rate limit exceeded")
                return

            content_length = int(self.headers.get('Content-Length', 0))
            if content_length == 0:
                self._send_error(400, "No data received")
                return

            post_data = self.rfile.read(content_length)

            try:
                data = json.loads(post_data.decode('utf-8'))
            except json.JSONDecodeError:
                data = parse_qs(post_data.decode('utf-8'))
                data = {k: v[0] if len(v) == 1 else v for k, v in data.items()}

            if CONFIG["auth_token"]:
                auth_header = self.headers.get('Authorization', '')
                if not self._verify_auth(auth_header, data):
                    self._send_error(401, "Unauthorized")
                    return

            normalized_signal = state.process_payload(data)
            save_state()
            self._write_to_mt5(normalized_signal)

            logger.info(f"Accepted webhook for {normalized_signal.get('symbol', 'UNKNOWN')}: {normalized_signal.get('signalType', normalized_signal.get('event', 'UNKNOWN'))}")
            self._send_json(200, {
                "success": True,
                "timestamp": datetime.utcnow().isoformat() + "Z",
                "accepted": normalized_signal,
            })

        except Exception as e:
            logger.error(f"Error processing webhook: {e}")
            self._send_error(500, str(e))

    def _check_rate_limit(self, ip):
        now = time.time()
        minute_ago = now - 60

        if ip not in state.last_signals:
            state.last_signals[ip] = []

        state.last_signals[ip] = [t for t in state.last_signals[ip] if t > minute_ago]

        if len(state.last_signals[ip]) >= CONFIG["max_signals_per_minute"]:
            return False

        state.last_signals[ip].append(now)
        return True

    def _verify_auth(self, auth_header, data):
        if auth_header.startswith('Bearer '):
            token = auth_header[7:]
            if token == CONFIG["auth_token"]:
                return True

        if data.get("auth_token") == CONFIG["auth_token"]:
            return True

        if "signature" in data and "timestamp" in data:
            expected = hmac.new(
                CONFIG["auth_token"].encode(),
                str(data["timestamp"]).encode(),
                hashlib.sha256
            ).hexdigest()
            return hmac.compare_digest(expected, data["signature"])

        return False

    def _write_to_mt5(self, signal_data):
        try:
            filepath = Path(CONFIG["mt5_files_path"]) / CONFIG["signal_file"]
            alt_paths = [Path.cwd() / "signals" / CONFIG["signal_file"]]

            for path in [filepath] + alt_paths:
                try:
                    path.parent.mkdir(parents=True, exist_ok=True)
                    with open(path, 'w', encoding='utf-8') as f:
                        json.dump(signal_data, f, indent=2)
                    return
                except Exception:
                    continue
        except Exception as e:
            logger.error(f"Error writing signal file: {e}")

    def _send_json(self, code, payload):
        self.send_response(code)
        self.send_header('Content-type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(payload).encode())

    def _send_error(self, code, message):
        self.send_response(code)
        self.send_header('Content-type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps({"error": message}).encode())


def run_server():
    server = HTTPServer((CONFIG["host"], CONFIG["port"]), WebhookHandler)
    logger.info("=" * 50)
    logger.info("DevyyTrades Webhook Server Started")
    logger.info(f"Listening on {CONFIG['host']}:{CONFIG['port']}")
    logger.info(f"Signal file: {CONFIG['signal_file']}")
    logger.info(f"State file: {CONFIG['state_file']}")
    logger.info("=" * 50)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info("Shutting down...")
        server.shutdown()


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="DevyyTrades Webhook Server")
    parser.add_argument("--port", type=int, default=8080, help="Server port")
    parser.add_argument("--mt5-path", type=str, help="Custom MT5 files path")
    parser.add_argument("--quiet", "-q", action="store_true", help="Suppress stdout logging")
    args = parser.parse_args()

    setup_logging(quiet=args.quiet)

    CONFIG["port"] = args.port
    if args.mt5_path:
        CONFIG["mt5_files_path"] = args.mt5_path

    run_server()
