# Quick Start Guide - DevyyTrades MT5 Webhook Bot

## Overview
This system automates your TradingView strategy by:
1. Receiving webhook signals from 3 indicators
2. Validating signals against all your rules
3. Executing trades in MT5

## Step-by-Step Setup (15 minutes)

### Step 1: Start the Webhook Server (2 min)

**Windows:**
```
Double-click: Scripts/start_server.bat
```

**Mac/Linux:**
```bash
cd MT5WebhookBot/Scripts
./start_server.sh
```

Verify it's running - you should see:
```
DevyyTrades Webhook Server Started
Listening on 0.0.0.0:8080
```

### Step 2: Get Your IP Address (1 min)

**Windows:**
```cmd
ipconfig
# Look for "IPv4 Address"
```

**Mac/Linux:**
```bash
ifconfig | grep "inet " | head -1
# or
hostname -I
```

Example: `192.168.1.100`

### Step 3: Modify TradingView Indicators (5 min)

For EACH of your 3 indicators:

1. Open Pine Script Editor (click "Pine Editor" tab)
2. Add the webhook code from `TradingView_PineScripts/` folder:
   - Copy contents of relevant `.pine` file
   - Paste at the END of your existing indicator code
3. Find `http://YOUR_IP:8080` and replace with your actual IP
4. Click "Add to Chart"
5. Click the alarm clock 🔔 next to the indicator
6. Set webhook URL: `http://YOUR_IP:8080`
7. Leave message blank (script builds it automatically)
8. Set frequency: `Once Per Bar Close`
9. Name it: e.g., "Wickless_EURUSD"
10. Click "Create"

**Repeat for all 3 indicators on all 4 pairs!**

### Step 4: Install MT5 EA (5 min)

1. Open MT5 → `File` → `Open Data Folder`
2. Copy files:
   ```
   MQL5/Experts/WebhookStrategyEA.mq5 → MQL5/Experts/
   MQL5/Include/*.mqh → MQL5/Include/
   ```
3. Open MetaEditor (F4)
4. Open `WebhookStrategyEA.mq5`
5. Press F7 (Compile)
6. Close MetaEditor

### Step 5: Configure MT5 (2 min)

**Enable Web Requests:**
1. `Tools` → `Options` → `Expert Advisors`
2. Check ✅ `Allow WebRequest for listed URL:`
3. Add: `http://localhost:8080` and `http://YOUR_IP:8080`

**Attach EA to Charts:**
1. Open chart for USDJPY, M15
2. Click `Navigator` → `Expert Advisors`
3. Drag `WebhookStrategyEA` to chart
4. Configure inputs:
   - Lot Size: `0.01` (start small!)
   - Max Risk: `2.0`
   - Webhook Port: `8080`
5. Check ✅ `Allow Algo Trading` (green button in toolbar)
6. Click `OK`

**Repeat for all pairs:** GBPUSD, AUDUSD, XAUUSD

## Verification Checklist

- [ ] Webhook server running and showing green status
- [ ] TradingView webhook alerts created for all 3 indicators
- [ ] All 4 pairs have EA attached with green "Algo Trading" button
- [ ] MT5 `Experts` tab showing "Webhook handler initialized"
- [ ] Test signal shows in MT5 logs

## Testing

### Test 1: Manual Webhook
```bash
# In new terminal
curl -X POST http://localhost:8080 \
  -H "Content-Type: application/json" \
  -d '{"indicator":"Wickless","signalType":"NOWICK_BULLISH","symbol":"EURUSD","price":1.0850}'
```

### Test 2: TradingView
1. Add webhook to indicator
2. Wait for signal on chart
3. Check MT5 `Experts` tab - should show "Received webhook signal"

## Common Issues

### "Connection Refused"
- Webhook server not running
- Wrong IP address
- Firewall blocking port 8080

### "EA Not Taking Trades"
- Check `Experts` tab for validation failures
- Verify trend is set (ChoCh/BOS must fire first)
- Check if outside trading hours

### "No Webhook Received"
- Verify TradingView alert is configured
- Check webhook URL is correct
- Ensure indicator is on active chart

## TradingView Alert Setup Summary

| Indicator | Alert Name Example | Webhook URL |
|-----------|-------------------|-------------|
| Wickless | Wickless_USDJPY_M15 | http://YOUR_IP:8080 |
| FVGs | FVG_4H_GBPUSD | http://YOUR_IP:8080 |
| News | News_USD_High | http://YOUR_IP:8080 |

**For each pair, you need 3 alerts (one per indicator)**
- USDJPY: Wickless, FVG, News
- GBPUSD: Wickless, FVG, News
- AUDUSD: Wickless, FVG, News
- XAUUSD: Wickless, FVG, News

**Total: 12 alerts to set up**

## Next Steps

1. **Demo Test** - Run on demo for 1 week
2. **Monitor Logs** - Check `webhook_server.log` and MT5 `Experts` tab
3. **Adjust Settings** - Modify `Config/settings.json` if needed
4. **Go Live** - Only after profitable demo period

## Important Notes

- Start with **0.01 lots** for testing
- **NEVER** trade during major news without news filter active
- EA will **NOT** take trades if any condition fails (this is by design!)
- All mechanical rules are enforced automatically

## Support

Check logs:
- `webhook_server.log` - Python server activity
- MT5 `Experts` tab - EA decisions and errors
- MT5 `Journal` tab - Trade execution details

---

**You're now ready to automate your mechanical strategy! 🚀**
