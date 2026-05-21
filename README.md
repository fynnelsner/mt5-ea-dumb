# DevyyTrades MT5 Webhook Strategy Bot

A complete automated trading system that receives webhook signals from TradingView indicators and executes trades in MetaTrader 5 based on your proven mechanical strategy.

## Architecture

```
TradingView (Pine Script with Webhooks)
    ↓ (HTTP POST webhook)
Python Webhook Server (webhook_server.py)
    ↓ (Writes to file)
MQL5 EA (WebhookStrategyEA.mq5)
    ↓ (Validates & Executes)
MetaTrader 5
```

## Strategy Rules Implemented

### Entry Rules
- ✅ **Trend Following**: Only trade with trend (BOS/ChoCh confirmation)
- ✅ **NoWick Candles**: Limit orders at open of 15min NoWick candles
- ✅ **Time Filter**: 8AM - 10PM CET trading hours
- ✅ **Asian Session Filter**: No trades 2h before/after Asian session
- ✅ **FVG Validation**: Don't trade against 4H/Daily imbalances
- ✅ **News Filter**: Exit 15min before red folder news

### Risk Management
- ✅ **Dynamic Position Sizing**: Based on 2% max risk per trade
- ✅ **Stop Loss**: Above/below recent swing points (max 50 pips)
- ✅ **Take Profit**: 1:2 Risk:Reward ratio
- ✅ **Breakeven**: Move to BE after 1R profit
- ✅ **Limit Order Expiry**: 2.5 hours

## Supported Pairs
- USDJPY
- GBPUSD
- AUDUSD
- XAUUSD

## Installation & Setup

### Step 1: TradingView Indicator Modification

You need to add webhook alerts to your existing 3 indicators:

#### 1. DevyyTrades Wickless
Add the Pine Script code from `TradingView_PineScripts/DevyyTrades_Wickless_Webhook.pine` to your existing indicator. This adds webhook alerts for:
- NoWick candle detection
- ChoCh (Change of Character)
- BOS (Break of Structure)

#### 2. FVGs DevyyTrades
Add the code from `TradingView_PineScripts/FVGs_DevyyTrades_Webhook.pine` to your FVG indicator. Sends webhooks for:
- 4H Fair Value Gaps
- Daily Fair Value Gaps

#### 3. News by @toodegrees
Add the code from `TradingView_PineScripts/News_toodegrees_Webhook.pine` to your news indicator. Sends webhooks for:
- High impact (red folder) news events
- Exit signals 15min before news
- Trading block signals

**Important**: Replace `http://YOUR_IP:8080` in all Pine Scripts with your actual IP address.

### Step 2: Start the Webhook Server

#### Option A: Local Machine (Recommended)
```bash
# Install Python dependencies (if any)
pip install -r Scripts/requirements.txt

# Run the webhook server
python Scripts/webhook_server.py --port 8080

# Or with custom MT5 path
python Scripts/webhook_server.py --port 8080 --mt5-path "C:/Users/YourName/.../Files"
```

#### Option B: Cloud/VPS
Deploy `webhook_server.py` to a VPS/cloud server and update the webhook URL in TradingView to your server's public IP/domain.

### Step 3: Install MQL5 Expert Advisor

1. Open MetaTrader 5
2. Navigate to `File` → `Open Data Folder`
3. Copy the files:
   - `MQL5/Experts/WebhookStrategyEA.mq5` → `MQL5/Experts/`
   - `MQL5/Include/WebhookHandler.mqh` → `MQL5/Include/`
   - `MQL5/Include/SignalValidator.mqh` → `MQL5/Include/`
   - `MQL5/Include/TradeManager.mqh` → `MQL5/Include/`

4. In MetaEditor, compile `WebhookStrategyEA.mq5` (F7)

### Step 4: Configure MT5

1. Open a chart for each pair (USDJPY, GBPUSD, AUDUSD, XAUUSD)
2. Set timeframe to M15
3. Attach `WebhookStrategyEA` to each chart
4. Configure inputs:
   - **Lot Size**: Start with 0.01 for testing
   - **Max Risk**: 2.0% recommended
   - **Webhook Port**: 8080 (must match Python server)
   - **Trading Hours**: 8-22 CET

### Step 5: Allow Web Requests in MT5

1. Go to `Tools` → `Options` → `Expert Advisors`
2. Check ✅ `Allow WebRequest for listed URL:`
3. Add: `http://localhost:8080` (or your webhook server URL)

### Step 6: Configure TradingView Alerts

For each indicator on your charts:
1. Click the alarm clock icon next to the indicator
2. Set webhook URL to: `http://YOUR_IP:8080`
3. Set message to: (leave empty - script builds the JSON)
4. Set frequency to: `Once Per Bar Close`
5. Name the alert: `Wickless_EURUSD`, `FVG_4H_USDJPY`, etc.

## Testing

### Test Webhook Server
```bash
# Run test signals
python Scripts/webhook_server.py --test
```

### Test MT5 EA
1. Set EA to use 0.01 lots
2. Enable `Visual Mode` in Strategy Tester
3. Run on historical data
4. Check `Experts` tab for log messages

## File Structure

```
MT5WebhookBot/
├── MQL5/
│   ├── Experts/
│   │   └── WebhookStrategyEA.mq5      # Main trading EA
│   └── Include/
│       ├── WebhookHandler.mqh         # Receives webhook data
│       ├── SignalValidator.mqh        # Validates all conditions
│       └── TradeManager.mqh           # Trade execution
├── Scripts/
│   └── webhook_server.py              # Python webhook receiver
├── TradingView_PineScripts/
│   ├── DevyyTrades_Wickless_Webhook.pine
│   ├── FVGs_DevyyTrades_Webhook.pine
│   └── News_toodegrees_Webhook.pine
├── Config/
│   └── settings.json                  # Configuration
└── README.md
```

## Configuration

Edit `Config/settings.json` to customize:

### Risk Management
```json
"risk_management": {
    "max_risk_per_trade": 2.0,      // Percentage of account
    "max_sl_pips": 50,              // Maximum SL distance
    "default_rr_ratio": 2.0         // Take profit ratio
}
```

### Trading Hours
```json
"trading_hours": {
    "start": "08:00",
    "end": "22:00",
    "timezone": "CET"
}
```

### Signal Validation
```json
"signal_validation": {
    "trend_confirmation": true,     // Require BOS/ChoCh
    "fvg_confirmation": true,       // Check 4H/Daily FVGs
    "news_filter": true             // Check news events
}
```

## How It Works

1. **TradingView** detects a NoWick candle, ChoCh/BOS, FVG, or News event
2. **Webhook** is sent to your Python server with JSON data
3. **Python Server** writes signal to file in MT5's Common/Files folder
4. **MQL5 EA** reads the file and validates:
   - Trend direction (from ChoCh/BOS)
   - FVG levels (not trading against imbalances)
   - News events (exit/block)
   - Trading hours and session filters
5. **MQL5 EA** places limit order if all conditions met
6. **MQL5 EA** monitors positions and manages:
   - Breakeven after 1R profit
   - Exit before news
   - SL/TP management

## Troubleshooting

### Webhooks Not Received
- Check firewall is allowing port 8080
- Verify TradingView webhook URL is correct
- Check Python server is running and listening
- Review `webhook_server.log`

### EA Not Taking Trades
- Check `Experts` tab in MT5 for errors
- Verify signal file exists in `Common/Files/`
- Check all validation conditions are met
- Ensure `AutoTrading` is enabled (green button)

### Wrong Time/Session Filtering
- Verify your server's timezone
- Check MT5's `Tools` → `Options` → `Server` timezone
- Adjust `g_serverOffset` in EA if needed

## Security

- Use authentication token in production
- Run webhook server behind firewall/VPN for production
- Don't expose webhook to public internet without auth
- Use HTTPS with reverse proxy for production

## Performance Notes

- The system runs on every tick (OnTick)
- Webhook processing is lightweight (file read)
- EA checks all conditions before placing orders
- Memory usage is minimal
- Works on standard VPS with 1GB RAM

## Future Enhancements

- [ ] Web dashboard for monitoring
- [ ] Telegram notifications
- [ ] Automatic backtesting report
- [ ] Multi-timeframe confirmation
- [ ] Dynamic risk adjustment based on win rate
- [ ] Integration with MyFxBook for tracking

## Support

For issues with:
- **Pine Script**: Check TradingView documentation
- **MQL5**: Check MetaTrader 5 documentation
- **Python Server**: Check logs in `webhook_server.log`

## License

Proprietary - For personal use only. Not for redistribution.

---

**Built by DevyyTrades** | Trade smart, trade mechanical 🚀
