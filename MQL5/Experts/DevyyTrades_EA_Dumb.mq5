//+------------------------------------------------------------------+
//|                                          DevyyTrades_EA_Dumb.mq5 |
//|                        Dumb Executor — polls /api/propose        |
//|                        Server decides; EA executes               |
//+------------------------------------------------------------------+
#property copyright     "DevyyTrades"
#property link          "https://devyytrades.com"
#property version       "2.01"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| INPUTS                                                           |
//+------------------------------------------------------------------+
input group "=== Server ==="
input string InpProposeUrl    = "https://ea.devyytrades.com/api/propose";
input string InpExecuteUrl    = "https://ea.devyytrades.com/api/propose/execute";
input int    InpPollIntervalS = 1;
input int    InpTimeoutMs     = 5000;

input group "=== Risk ==="
input ulong  InpMagicNumber   = 42069;
input double InpRiskPercent   = 1.0;
input int    InpSlippage      = 30;

input group "=== Filters ==="
input bool   InpCheckExpiry   = true;
input bool   InpDivergenceFix = true;  // Adjust entry/SL/TP for TW vs MT5 price diff

//+------------------------------------------------------------------+
//| GLOBALS                                                          |
//+------------------------------------------------------------------+
CTrade      g_trade;
string      g_executedIds[1000];
int         g_executedCount = 0;
string      g_pendingIds[1000];
int         g_pendingCount  = 0;
int         g_exportCounter = 0;
int         g_signalTimeframe = 15;  // All proposals are on 15m TF

//+------------------------------------------------------------------+
//| Init                                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   Print("[EA_Dumb] Init - polling ", InpProposeUrl);
   
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpSlippage);
   g_trade.SetAsyncMode(false);
   
   // Show whitelist hint
   string host = InpProposeUrl;
   StringReplace(host, "https://", "");
   int pos = StringFind(host, "/");
   if(pos != -1) host = StringSubstr(host, 0, pos);
   Print("[EA_Dumb] === Allow URL in MT5: Tools -> Options -> Expert Advisors -> ", host, " ===");
   
   EventSetTimer(InpPollIntervalS);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Deinit                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   Print("[EA_Dumb] Deinit");
  }

//+------------------------------------------------------------------+
//| Timer - poll /api/propose                                         |
//+------------------------------------------------------------------+
void OnTimer()
  {
   g_exportCounter++;
   if(g_exportCounter % 5 == 0) ExportAccountData();
   string json = HttpGet(InpProposeUrl + "?balance=" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2));
   if(StringLen(json) < 20)
     {
      Print("[EA_Dumb] Listening... (no response)");
      return;
     }
   
   // Extract proposals array using string parsing
   int proposalsPos = StringFind(json, "\"proposals\"");
   if(proposalsPos < 0)
     {
      Print("[EA_Dumb] Listening... (no proposals in response)");
      return;
     }
   
   int arrStart = StringFind(json, "[", proposalsPos);
   int arrEnd   = FindMatchingBracket(json, arrStart);
   if(arrStart < 0 || arrEnd < 0)
     {
      Print("[EA_Dumb] ERROR: Could not parse proposals array in response");
      return;
     }
   
   string arr = StringSubstr(json, arrStart+1, arrEnd - arrStart - 1);
   
   // Split into individual proposal objects
   string proposals[];
   SplitProposals(arr, proposals);
   
   int count = ArraySize(proposals);
   for(int i=0; i<count; i++)
     {
      string p = proposals[i];
      if(StringLen(p) < 10)
        {
         Print("[EA_Dumb] SKIP: proposal too short: ", p);
         continue;
        }
      
      string setupId = JsonStr(p, "setup_id");
      string symbol  = JsonStr(p, "symbol");
      string action  = JsonStr(p, "action");
      string dir     = JsonStr(p, "direction");
      double entry   = JsonDbl(p, "entry");
      double sl      = JsonDbl(p, "sl");
      double tp      = JsonDbl(p, "tp");
      double lots    = JsonDbl(p, "lots");
      long   expires = (long)JsonDbl(p, "expires_at_unix");
      long   barTimeMs = (long)JsonDbl(p, "bar_time");  // Unix ms from proposal
      
      // ============================================================
      // DUPLICATE PROTECTION: Check if this setup already has an
      // active order or open position on MT5 (survives restart)
      // ============================================================
      if(HasOrderForSetupId(setupId))
        {
         Print("[EA_Dumb] DUPLICATE GUARD: ", setupId, " already in MT5 history - skipping + cleanup");
         // Try to clean up stale proposal from server (in case PostExecute failed earlier)
         PostExecute(setupId);
         SessionAdd(g_executedIds, g_executedCount, setupId);
         continue;
        }
      
      // Skip already executed this session
      if(SessionHas(g_executedIds, g_executedCount, setupId)) continue;
      
      if(action == "place")
        {
         // Check expiry
         if(InpCheckExpiry && expires > 0 && TimeGMT() > expires)
           {
            Print("[EA_Dumb] SKIP expired: ", setupId);
            SessionAdd(g_executedIds, g_executedCount, setupId);
            continue;
           }
         
         // Check if already pending
         if(SessionHas(g_pendingIds, g_pendingCount, setupId)) continue;
         
         // Check if opposing position exists
         if(HasOpposingPosition(symbol, dir))
           {
            Print("[EA_Dumb] SKIP opposing position: ", setupId);
            SessionAdd(g_executedIds, g_executedCount, setupId);
            continue;
           }
         
         // ============================================================
         // PRICE DIVERGENCE FIX: Adjust entry/SL/TP for TW vs MT5 diff
         // ============================================================
         double adjEntry = entry;
         double adjSl    = sl;
         double adjTp    = tp;
         double divergence = 0.0;
         
         if(InpDivergenceFix && barTimeMs > 0)
           {
            divergence = GetDivergence(symbol, entry, barTimeMs);
            if(divergence != 0.0)
              {
               adjEntry = entry - divergence;
               adjSl    = sl - divergence;
               adjTp    = tp - divergence;
               Print("[EA_Dumb] DIVERGENCE: ", symbol, " TW_open=", entry, " MT5_open=", entry-divergence, " diff=", divergence, " -> adj entry=", adjEntry, " adjSL=", adjSl, " adjTP=", adjTp);
              }
            else
              {
               Print("[EA_Dumb] DIVERGENCE: ", symbol, " could not get MT5 candle open - using original levels");
              }
           }
         
         bool ok = PlaceOrder(symbol, dir, adjEntry, adjSl, adjTp, setupId, lots);
         if(ok)
           {
            SessionAdd(g_executedIds, g_executedCount, setupId);
            SessionAdd(g_pendingIds, g_pendingCount, setupId);
            PostExecute(setupId);
            Print("[EA_Dumb] PLACED ", setupId, " ", symbol, " ", dir, " entry=", adjEntry, " (divergence=", divergence, ")");
           }
         else
           {
            Print("[EA_Dumb] FAILED ", setupId, " ", symbol, " ", dir, " entry=", adjEntry);
            // Even on failure, add to executed to prevent re-trying the same setup
            SessionAdd(g_executedIds, g_executedCount, setupId);
           }
        }
      else if(action == "cancel")
        {
         CancelOrderBySetupId(setupId);
         SessionAdd(g_executedIds, g_executedCount, setupId);
         PostExecute(setupId);
         Print("[EA_Dumb] CANCELLED ", setupId);
        }
     }
   
   Print("[EA_Dumb] Listening... (", count, " proposals checked)");
  }

//+------------------------------------------------------------------+
//| GetDivergence — compute TW vs MT5 candle open diff               |
//| Returns the amount to SUBTRACT from TW prices to get MT5 prices  |
//| Positive = TW higher than MT5, Negative = TW lower than MT5      |
//|                                                                  |
//| barTimeMs = unix epoch in milliseconds from proposal JSON         |
//+------------------------------------------------------------------+
double GetDivergence(string sym, double twOpen, long barTimeMs)
  {
   // Convert bar_time (unix ms) to MT5 datetime (unix seconds)
   datetime barTime = (datetime)(barTimeMs / 1000);
   
   // barTime is the candle open time (e.g., 15m candle start)
   // Use CopyRates to get the candle at that exact time
   MqlRates rates[];
   ResetLastError();
   int copied = CopyRates(sym, PERIOD_M15, barTime, 1, rates);
   if(copied != 1)
     {
      Print("[EA_Dumb] GetDivergence: CopyRates failed for ", sym, " barTime=", barTime, " copied=", copied, " err=", GetLastError());
      return 0.0;
     }
   
   double mt5Open = rates[0].open;
   if(mt5Open <= 0)
     {
      Print("[EA_Dumb] GetDivergence: invalid MT5 open price (", mt5Open, ") for ", sym);
      return 0.0;
     }
   
   double divergence = twOpen - mt5Open;
   
   Print("[EA_Dumb] GetDivergence: ", sym, " TW_open=", twOpen, " MT5_open=", mt5Open, " diff=", divergence);
   
   // Sanity check: divergence should be reasonable (< 0.5% of price)
   // If it's huge, something is wrong (wrong candle, data issue)
   double maxDivergence = twOpen * 0.005;
   if(MathAbs(divergence) > maxDivergence)
     {
      Print("[EA_Dumb] GetDivergence: divergence too large (", divergence, " > ", maxDivergence, "), ignoring");
      return 0.0;
     }
   
   return divergence;
  }

//+------------------------------------------------------------------+
//| HasOrderForSetupId — check if any MT5 order/position has this    |
//| setup_id in its comment. Survives EA restart since it checks     |
//| actual trades on the terminal.                                   |
//+------------------------------------------------------------------+
bool HasOrderForSetupId(string setupId)
  {
   if(StringLen(setupId) == 0) return false;
   
   // Check open positions
   int posTotal = PositionsTotal();
   for(int i=0; i<posTotal; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      string comment = PositionGetString(POSITION_COMMENT);
      if(comment == setupId)
        {
         Print("[EA_Dumb] DUPLICATE GUARD: found position with comment=", setupId);
         return true;
        }
     }
   
   // Check pending orders
   int ordTotal = OrdersTotal();
   for(int i=0; i<ordTotal; i++)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;
      string comment = OrderGetString(ORDER_COMMENT);
      if(comment == setupId)
        {
         Print("[EA_Dumb] DUPLICATE GUARD: found pending order with comment=", setupId);
         return true;
        }
     }
   
   // Also check recent history (last 24h) as a safety net
   datetime from = TimeGMT() - 86400;  // 24 hours back
   datetime to   = TimeGMT() + 3600;   // 1 hour in the future
   if(HistorySelect(from, to))
     {
      int total = HistoryOrdersTotal();
      for(int i=0; i<total; i++)
        {
         ulong ticket = HistoryOrderGetTicket(i);
         if(ticket == 0) continue;
         if(HistoryOrderGetInteger(ticket, ORDER_MAGIC) != InpMagicNumber) continue;
         string comment = HistoryOrderGetString(ticket, ORDER_COMMENT);
         if(comment == setupId)
           {
            Print("[EA_Dumb] DUPLICATE GUARD: found historical order with comment=", setupId);
            return true;
           }
        }
     }
   
   return false;
  }

//+------------------------------------------------------------------+
//| PlaceOrder                                                       |
//+------------------------------------------------------------------+
bool PlaceOrder(string sym, string dir, double entry, double sl, double tp, string setupId, double lots=0)
  {
   // Log what we're about to do
   Print("[EA_Dumb] Attempting order: ", sym, " ", dir, " entry=", entry, " sl=", sl, " tp=", tp);
   
   if(StringLen(sym) == 0)
     {
      Print("[EA_Dumb] Empty symbol in proposal");
      return false;
     }
   
   // Select symbol (try plain name + common suffixes)
   string symEffective = sym;
   if(sym != _Symbol)
     {
      // Try plain name first
      if(!SymbolSelect(sym, true))
        {
         // Try common broker suffixes
         string suffixes[] = {"+", "m", "c", "_r", "."};
         bool found = false;
         for(int s=0; s<ArraySize(suffixes); s++)
           {
            string candidate = sym + suffixes[s];
            if(SymbolSelect(candidate, true))
              {
               symEffective = candidate;
               found = true;
               Print("[EA_Dumb] Using broker suffix variant: ", candidate);
               break;
              }
           }
         if(!found)
           {
            Print("[EA_Dumb] SymbolSelect failed: ", sym);
            return false;
           }
        }
     }
   
   // Wait for symbol prices with retry (up to 3s total)
   double bid = 0, ask = 0;
   for(int retry=0; retry<30; retry++)
     {
      bid = SymbolInfoDouble(symEffective, SYMBOL_BID);
      ask = SymbolInfoDouble(symEffective, SYMBOL_ASK);
      if(bid > 0 && ask > 0) break;
      Sleep(100);
     }
   if(bid == 0 || ask == 0)
     {
      Print("[EA_Dumb] No price for ", symEffective, " after 3s retries");
      return false;
     }
   
   ENUM_ORDER_TYPE otype;
   bool useMarketOrder = false;
   
   if(dir == "buy")
     {
      if(ask <= entry)
        {
         // Market at or below entry -> buy at same/better price via market order
         otype = ORDER_TYPE_BUY;
         useMarketOrder = true;
         Print("[EA_Dumb] Price below buy limit (ask=", ask, " <= entry=", entry, ") -> using MARKET BUY");
        }
      else
        {
         // Market above entry -> wait for pullback with BUY_LIMIT
         otype = ORDER_TYPE_BUY_LIMIT;
         useMarketOrder = false;
        }
     }
   else if(dir == "sell")
     {
      if(bid >= entry)
        {
         // Market at or above entry -> sell at same/better price via market order
         otype = ORDER_TYPE_SELL;
         useMarketOrder = true;
         Print("[EA_Dumb] Price above sell limit (bid=", bid, " >= entry=", entry, ") -> using MARKET SELL");
        }
      else
        {
         // Market below entry -> wait for bounce with SELL_LIMIT
         otype = ORDER_TYPE_SELL_LIMIT;
         useMarketOrder = false;
        }
     }
   else
     {
      Print("[EA_Dumb] Unknown direction: ", dir);
      return false;
     }
   
   // ALWAYS calculate lot dynamically based on actual entry-SL distance for fixed 1% risk
   // Backend lots field is IGNORED - EA has real-time balance, backend uses stale env var
   double lot = CalcLot(sym, MathAbs(entry - sl));
   Print("[EA_Dumb] Dynamic lot calc: ", lot, " for ", sym, " sl_dist=", MathAbs(entry - sl));
   // NUCLEAR SAFETY CAP: never risk more than 5 lots
   double MAX_LOT = 5.0;
   if(lot > MAX_LOT)
     {
      Print("[EA_Dumb] LOT CAP TRIGGERED: ", lot, " capped to ", MAX_LOT, " for ", sym);
      lot = MAX_LOT;
     }

   if(lot <= 0)
     {
      Print("[EA_Dumb] Invalid lot size for ", sym, " entry=", entry, " sl=", sl);
      return false;
     }
   
   int digits = (int)SymbolInfoInteger(symEffective, SYMBOL_DIGITS);
   
   MqlTradeRequest req = {};
   req.symbol       = symEffective;
   req.volume       = NormalizeDouble(lot, 2);
   req.deviation    = InpSlippage;
   req.magic        = InpMagicNumber;
   req.comment      = setupId;
   req.type_filling = ORDER_FILLING_RETURN;
   
   if(useMarketOrder)
     {
      // Use actual market price for SL/TP normalization
      double fillPrice = (dir == "buy") ? ask : bid;
      double actualSlDist = MathAbs(fillPrice - sl);
      double actualTpDist = MathAbs(fillPrice - tp);
      
      req.action = TRADE_ACTION_DEAL;
      req.type   = otype;
      req.price  = (dir == "buy") ? ask : bid;
      req.sl     = NormalizeDouble(sl, digits);
      req.tp     = NormalizeDouble(tp, digits);
     }
   else
     {
      req.action = TRADE_ACTION_PENDING;
      req.type   = otype;
      req.price  = NormalizeDouble(entry, digits);
      req.sl     = NormalizeDouble(sl, digits);
      req.tp     = NormalizeDouble(tp, digits);
     }
   
   // Cancel any existing pending orders for this setup_id first
   CancelOrderBySetupId(setupId);
   
   MqlTradeResult res = {};
   if(!OrderSend(req, res))
     {
      Print("[EA_Dumb] OrderSend failed: ", GetLastError(), " retcode=", res.retcode);
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| CancelOrderBySetupId                                             |
//+------------------------------------------------------------------+
void CancelOrderBySetupId(string setupId)
  {
   int total = OrdersTotal();
   for(int i=total-1; i>=0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_COMMENT) == setupId && OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
        {
         g_trade.OrderDelete(ticket);
         Print("[EA_Dumb] Deleted order #", ticket, " for ", setupId);
         break;
        }
     }
  }

//+------------------------------------------------------------------+
//| HasOpposingPosition                                              |
//+------------------------------------------------------------------+
bool HasOpposingPosition(string sym, string dir)
  {
   int total = PositionsTotal();
   for(int i=0; i<total; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      
      long posType = PositionGetInteger(POSITION_TYPE);
      if(dir == "buy" && posType == POSITION_TYPE_SELL) return true;
      if(dir == "sell" && posType == POSITION_TYPE_BUY) return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| CalcLot                                                          |
//+------------------------------------------------------------------+
double CalcLot(string sym, double slDist)
  {
   double tickSize = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double tickVal  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize == 0 || tickVal == 0) return 0;
   
   double riskAmt  = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
   double ticks    = slDist / tickSize;
   double lot      = riskAmt / (ticks * tickVal);
   double minLot   = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxLot   = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double lotStep  = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   
   lot = MathFloor(lot / lotStep) * lotStep;
   lot = MathMax(minLot, MathMin(maxLot, lot));
   return lot;
  }

//+------------------------------------------------------------------+
//| PostExecute - ack back to server with retry                      |
//+------------------------------------------------------------------+
void PostExecute(string setupId)
  {
   string url = InpExecuteUrl;
   if(StringLen(url) == 0) url = InpProposeUrl + "/execute";
   
   string body = "{\"setup_id\":\"" + setupId + "\",\"executed_at\":\"" + TimeToString(TimeGMT()) + "\"}";
   char data[], resp[];
   string resp_headers;
   StringToCharArray(body, data);
   ArrayResize(data, ArraySize(data) - 1);  // CRITICAL: Strip null terminator from StringToCharArray
   
   // Retry up to 3 times with 1s delay
   bool success = false;
   for(int retry=0; retry<3 && !success; retry++)
     {
      int res = WebRequest("POST", url, NULL, InpTimeoutMs, data, resp, resp_headers);
      if(res == 200)
        {
         string responseText = CharArrayToString(resp);
         success = true;
         Print("[EA_Dumb] Execute ack OK: ", setupId, " response=", responseText);
        }
      else
        {
         string responseText = CharArrayToString(resp);
         Print("[EA_Dumb] Execute ack FAILED (attempt ", retry+1, "): res=", res, " for ", setupId, " response=", responseText);
         if(retry < 2) Sleep(1000);
        }
     }
   
   if(!success)
     {
      Print("[EA_Dumb] CRITICAL: Execute ack failed after 3 retries for ", setupId, " - proposal will NOT be deleted!");
      Print("[EA_Dumb] CRITICAL: But DUPLICATE GUARD will prevent re-taking this setup");
     }
  }

//+------------------------------------------------------------------+
//| HttpGet                                                          |
//+------------------------------------------------------------------+
string HttpGet(string url)
  {
   char data[], result[];
   string headers, result_headers;
   int res = WebRequest("GET", url, headers, InpTimeoutMs, data, result, result_headers);
   if(res != 200)
     {
      // Print("[EA_Dumb] HTTP GET failed: ", res); // Reduce noise
      return "";
     }
   return CharArrayToString(result);
  }

//+------------------------------------------------------------------+
//| JSON string parser (no library needed)                            |
//+------------------------------------------------------------------+
string JsonStr(string json, string key)
  {
   string search = "\"" + key + "\"";
   int pos = StringFind(json, search);
   if(pos < 0) return "";
   pos = StringFind(json, "\"", pos + StringLen(search));
   if(pos < 0) return "";
   int end = StringFind(json, "\"", pos + 1);
   if(end < 0) return "";
   return StringSubstr(json, pos + 1, end - pos - 1);
  }

double JsonDbl(string json, string key)
  {
   string search = "\"" + key + "\"";
   int pos = StringFind(json, search);
   if(pos < 0) return 0;
   pos = StringFind(json, ":", pos + StringLen(search));
   if(pos < 0) return 0;
   pos++;
   // Skip whitespace
   while(pos < StringLen(json) && (StringGetCharacter(json, pos) == ' ' || StringGetCharacter(json, pos) == '\t'))
      pos++;
   
   int end = pos;
   while(end < StringLen(json))
     {
      uchar c = (uchar)StringGetCharacter(json, end);
      if(c >= '0' && c <= '9') end++;
      else if(c == '.' || c == '-' || c == 'e' || c == 'E' || c == '+') end++;
      else break;
     }
   string val = StringSubstr(json, pos, end - pos);
   return StringToDouble(val);
  }

//+------------------------------------------------------------------+
//| Split proposals array into individual objects                     |
//+------------------------------------------------------------------+
void SplitProposals(string arrText, string &out[])
  {
   int depth = 0;
   int start = 0;
   int count = 0;
   
   for(int i=0; i<StringLen(arrText); i++)
     {
      uchar c = (uchar)StringGetCharacter(arrText, i);
      if(c == '{')
        {
         if(depth == 0) start = i;
         depth++;
        }
      else if(c == '}')
        {
         depth--;
         if(depth == 0)
           {
            ArrayResize(out, count+1);
            out[count] = StringSubstr(arrText, start, i - start + 1);
            count++;
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Find matching bracket                                             |
//+------------------------------------------------------------------+
int FindMatchingBracket(string s, int openPos)
  {
   if(openPos < 0 || openPos >= StringLen(s)) return -1;
   if(StringGetCharacter(s, openPos) != '[' && StringGetCharacter(s, openPos) != '{') return -1;
   
   ushort openChar = StringGetCharacter(s, openPos);
   ushort closeChar = (openChar == '[') ? ']' : '}';
   int depth = 1;
   
   for(int i=openPos+1; i<StringLen(s); i++)
     {
      ushort c = StringGetCharacter(s, i);
      if(c == openChar) depth++;
      else if(c == closeChar)
        {
         depth--;
         if(depth == 0) return i;
        }
     }
   return -1;
  }

//+------------------------------------------------------------------+
//| Session array helpers                                             |
//+------------------------------------------------------------------+
bool SessionHas(string &arr[], int &count, string val)
  {
   for(int i=0; i<count; i++)
      if(arr[i] == val) return true;
   return false;
  }

void SessionAdd(string &arr[], int &count, string val)
  {
   if(count >= ArraySize(arr)) return; // Full
   arr[count] = val;
   count++;
  }
//+------------------------------------------------------------------+



//+------------------------------------------------------------------+
//| ExportAccountData — writes account, positions, history to JSON    |
//+------------------------------------------------------------------+
void ExportAccountData()
  {
   string path = "Z:/home/devyytrades/ea-server/feeds/mt5_account.json";
   string json = "{";

   // Account
   json += "\"account\":{"
           + "\"login\":"       + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + ","
           + "\"name\":\""       + AccountInfoString(ACCOUNT_NAME) + "\","
           + "\"server\":\""     + AccountInfoString(ACCOUNT_SERVER) + "\","
           + "\"company\":\""    + AccountInfoString(ACCOUNT_COMPANY) + "\","
           + "\"currency\":\""   + AccountInfoString(ACCOUNT_CURRENCY) + "\","
           + "\"leverage\":"     + IntegerToString(AccountInfoInteger(ACCOUNT_LEVERAGE)) + ","
           + "\"balance\":"      + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + ","
           + "\"equity\":"       + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2) + ","
           + "\"margin\":"       + DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN), 2) + ","
           + "\"free_margin\":"  + DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE), 2) + ","
           + "\"profit\":"       + DoubleToString(AccountInfoDouble(ACCOUNT_PROFIT), 2) + ","
           + "\"credit\":"       + DoubleToString(AccountInfoDouble(ACCOUNT_CREDIT), 2)
           + "},";

   // Positions
   json += "\"positions\":[";
   int posTotal = PositionsTotal();
   for(int i = 0; i < posTotal; i++)
     {
      string sym = PositionGetSymbol(i);
      if(sym == "") continue;
      ulong  ticket   = PositionGetInteger(POSITION_TICKET);
      string type     = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "buy" : "sell";
      double lots     = PositionGetDouble(POSITION_VOLUME);
      double entry    = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl       = PositionGetDouble(POSITION_SL);
      double tp       = PositionGetDouble(POSITION_TP);
      double profit   = PositionGetDouble(POSITION_PROFIT);
      datetime openAt = (datetime)PositionGetInteger(POSITION_TIME);
      string comment  = PositionGetString(POSITION_COMMENT);
      int dig = (StringFind(sym, "JPY") >= 0 || sym == "XAUUSD") ? 3 : 5;
      if(i > 0) json += ",";
      json += "{"
              + "\"ticket\":"    + IntegerToString((long)ticket) + ","
              + "\"symbol\":\""  + sym + "\","
              + "\"direction\":\""+ type + "\","
              + "\"lots\":"     + DoubleToString(lots, 2) + ","
              + "\"entry\":"    + DoubleToString(entry, dig) + ","
              + "\"sl\":"       + DoubleToString(sl, dig) + ","
              + "\"tp\":"       + DoubleToString(tp, dig) + ","
              + "\"profit\":"   + DoubleToString(profit, 2) + ","
              + "\"opened_at\":"+ IntegerToString((long)openAt) + ","
              + "\"comment\":\"" + comment + "\""
              + "}";
     }
   json += "],";

   // Pending orders
   json += "\"pending_orders\":[";
   int ordTotal = OrdersTotal();
   for(int i = 0; i < ordTotal; i++)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      string sym = OrderGetString(ORDER_SYMBOL);
      if(sym == "") continue;
      long type     = OrderGetInteger(ORDER_TYPE);
      string typeStr = (type == ORDER_TYPE_BUY_LIMIT ? "buy_limit" : (type == ORDER_TYPE_SELL_LIMIT ? "sell_limit" : (type == ORDER_TYPE_BUY_STOP ? "buy_stop" : (type == ORDER_TYPE_SELL_STOP ? "sell_stop" : "unknown"))));
      double lots   = OrderGetDouble(ORDER_VOLUME_CURRENT);
      double price  = OrderGetDouble(ORDER_PRICE_OPEN);
      double sl     = OrderGetDouble(ORDER_SL);
      double tp     = OrderGetDouble(ORDER_TP);
      datetime openAt = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      string comment = OrderGetString(ORDER_COMMENT);
      long timeExp = OrderGetInteger(ORDER_TIME_EXPIRATION);
      int dig = (StringFind(sym, "JPY") >= 0 || sym == "XAUUSD") ? 3 : 5;
      if(i > 0) json += ",";
      json += "{"
              + "\"ticket\":"    + IntegerToString((long)ticket) + ","
              + "\"symbol\":\""  + sym + "\","
              + "\"type\":\""    + typeStr + "\","
              + "\"lots\":"     + DoubleToString(lots, 2) + ","
              + "\"price\":"    + DoubleToString(price, dig) + ","
              + "\"sl\":"       + DoubleToString(sl, dig) + ","
              + "\"tp\":"       + DoubleToString(tp, dig) + ","
              + "\"expires_at\":"+ IntegerToString(timeExp) + ","
              + "\"comment\":\"" + comment + "\""
              + "}";
     }
   json += "],";

   // History (last 100 deals)
   if(HistorySelect(0, TimeCurrent()))
     {
      json += "\"history\":[";
      int dealTotal = HistoryDealsTotal();
      int exported = 0;
      for(int i = dealTotal - 1; i >= 0 && exported < 100; i--)
        {
         ulong ticket = HistoryDealGetTicket(i);
         if(ticket == 0) continue;
         string sym = HistoryDealGetString(ticket, DEAL_SYMBOL);
         if(sym == "") continue;
         long orderTicket = HistoryDealGetInteger(ticket, DEAL_ORDER);
         long entryType   = HistoryDealGetInteger(ticket, DEAL_ENTRY);
         long dealType    = HistoryDealGetInteger(ticket, DEAL_TYPE);
         double lots      = HistoryDealGetDouble(ticket, DEAL_VOLUME);
         double price     = HistoryDealGetDouble(ticket, DEAL_PRICE);
         double profit    = HistoryDealGetDouble(ticket, DEAL_PROFIT);
         double swap      = HistoryDealGetDouble(ticket, DEAL_SWAP);
         double commission= HistoryDealGetDouble(ticket, DEAL_COMMISSION);
         datetime dealAt  = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
         string comment   = HistoryDealGetString(ticket, DEAL_COMMENT);
         string dir = (dealType == DEAL_TYPE_BUY) ? "buy" : "sell";
         string entryLabel = (entryType == DEAL_ENTRY_IN) ? "open" : (entryType == DEAL_ENTRY_OUT ? "close" : "inout");
         int dig = (StringFind(sym, "JPY") >= 0 || sym == "XAUUSD") ? 3 : 5;
         if(exported > 0) json += ",";
         json += "{"
                 + "\"ticket\":"    + IntegerToString((long)ticket) + ","
                 + "\"order\":"     + IntegerToString(orderTicket) + ","
                 + "\"symbol\":\""  + sym + "\","
                 + "\"direction\":\""+ dir + "\","
                 + "\"entry_type\":\""+ entryLabel + "\","
                 + "\"lots\":"     + DoubleToString(lots, 2) + ","
                 + "\"price\":"    + DoubleToString(price, dig) + ","
                 + "\"profit\":"   + DoubleToString(profit, 2) + ","
                 + "\"swap\":"     + DoubleToString(swap, 2) + ","
                 + "\"commission\":"+ DoubleToString(commission, 2) + ","
                 + "\"time\":"     + IntegerToString((long)dealAt) + ","
                 + "\"comment\":\"" + comment + "\""
                 + "}";
         exported++;
        }
      json += "]";
     }
   else
     {
      json += "\"history\":[]";
     }

   // Include divergence info
   json += ",\"divergence_enabled\":" + (InpDivergenceFix ? "true" : "false");

   json += "}";

   int handle = FileOpen(path, FILE_WRITE|FILE_TXT);
   if(handle != INVALID_HANDLE)
     {
      FileWriteString(handle, json);
      FileClose(handle);
     }
   else
     {
      Print("[EA_Dumb] ExportAccountData: failed to open ", path);
     }
  }
