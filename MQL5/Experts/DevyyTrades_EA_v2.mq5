//+------------------------------------------------------------------+
//|                                              DevyyTrades_EA_v2 |
//|    Webhook-based Wickless + FVG + News Automated Trading System  |
//+------------------------------------------------------------------+
#property copyright "DevyyTrades"
#property version   "4.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//+------------------------------------------------------------------+
//| INPUTS                                                            |
//+------------------------------------------------------------------+
input group "=== WEBHOOK / DATA ==="
input string InpWebhookUrl      = "https://ea.devyytrades.com";
input string InpApiKey          = "";       // optional

input group "=== PAIRS ==="
input string InpAllowedSymbols  = "USDJPY,GBPUSD,GBPUSD+,AUDUSD,AUDUSD+,XAUUSD,XAUUSD+.";
input int    InpMaxPositions    = 4;         // max open positions

input group "=== LOT / RISK ==="
input double InpLotSize         = 0.1;       // fixed lot fallback (only used if MaxRiskPct = 0)
input double InpMaxRiskPct      = 1.0;       // max risk % per trade (0 = use LotSize)

input group "=== SL / TP / ENTRY ==="
input int    InpMinSLPips       = 10;        // min SL distance (pips)
input int    InpMaxSLPips       = 35;        // max SL distance (pips)
input int    InpFallbackMinPips = 15;        // min on 5m / 1m fallback
input int    InpBreathingPct    = 10;        // SL breathing room %
input double InpTPRatio          = 1.0;        // R:R (1.0 = 1:1)
input int    InpDevyyEntryPips  = 2;         // Devyy entry offset (>10pips only)

input group "=== FILTER / NEWS ==="
input bool   InpUseTimeFilter   = true;
input int    InpTradeStartHour  = 8;         // CET
input int    InpTradeEndHour    = 22;        // CET
input int    InpNewsBufferMin   = 30;        // news block before (mins)
input int    InpNewsExitMin     = 15;        // close positions before (mins)
input bool   InpAutoCloseNews   = true;

input group "=== ORDER EXPIRY ==="
input int    InpCandleExpiry    = 10;        // cancel limit after N candles

input group "=== POLLING ==="
input int    InpPollIntervalSec = 2;         // seconds
input int    InpNewsPollMin     = 5;         // minutes

//+------------------------------------------------------------------+
//| STRUCTS                                                           |
//+------------------------------------------------------------------+
struct EventData {
   string   rawJson;
   string   received_at;
   string   symbol;
   string   direction;     // bullish / bearish
   string   timeframe;     // 1,5,15,60,240
   double   entry_anchor;
   double   candle_high;
   double   candle_low;
   double   structure_high;
   double   structure_low;
   string   trend_dir;
   string   recent_struct_json;
   string   fvgs_json;     // embedded FVGs from webhook payload (PRIMARY source)
};

struct FvgZone {
   string   direction;
   double   zone_top;
   double   zone_bottom;
   string   state;
};

struct NewsEvent {
   string   title;
   string   currency;
   string   affected_pairs;
   string   utc_time;
};

struct PendingSetup {
   ulong    orderTicket;
   string   symbol;
   datetime placeTime;
   int      tfMinutes;
   string   eventReceivedAt;
   string   direction;
   double   entryAnchor;
   string   recentStructJson;
   string   fvgsJson;
};

//+------------------------------------------------------------------+
//| GLOBALS                                                           |
//+------------------------------------------------------------------+
CTrade      g_trade;
CPositionInfo g_posInfo;
COrderInfo  g_orderInfo;

string      g_lastEventReceivedAt = "";
string      g_cachedNewsJson    = "";
string      g_cachedFvgState  = ""; // polled from /api/fvg-periodic-updates
datetime    g_lastFvgPoll      = 0;
datetime    g_lastNewsPoll      = 0;
datetime    g_lastEventsPoll    = 0;
PendingSetup g_pendingSetups[];
string      g_logFile           = "DevyyTrades_EA_v2.log";

//+------------------------------------------------------------------+
//| UTIL: Logging                                                     |
//+------------------------------------------------------------------+
void LogMsg(string msg) {
   string line = TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS) + " | " + msg;
   Print(line);
   int h = FileOpen(g_logFile,FILE_WRITE|FILE_TXT|FILE_COMMON|FILE_READ);
   if(h != INVALID_HANDLE) {
      FileSeek(h,0,SEEK_END);
      FileWriteString(h,line+"\r\n");
      FileClose(h);
   }
}

//+------------------------------------------------------------------+
//| UTIL: HTTP GET                                                    |
//+------------------------------------------------------------------+
int HttpGet(string url, string &response) {
   uchar data[], result[];
   string headers, result_headers;
   int res = WebRequest("GET",url,headers,8000,data,result,result_headers);
   if(res == 200) {
      response = CharArrayToString(result);
      return 200;
   }
   return res;
}

//+------------------------------------------------------------------+
//| UTIL: JSON helpers (manual string-based)                        |
//+------------------------------------------------------------------+
string JsonStrVal(string json, string key) {
   string k = "\"" + key + "\"";
   int p = StringFind(json,k);
   if(p < 0) return "";
   int i = p + StringLen(k);
   while(i < StringLen(json) && (json[i]==' ' || json[i]==':' || json[i]=='\t')) i++;
   if(i >= StringLen(json)) return "";
   if(json[i]=='"') {
      i++;
      int e = StringFind(json,"\"",i);
      if(e < 0) return "";
      return StringSubstr(json,i,e-i);
   }
   int e = StringFind(json,",",i);
   int b = StringFind(json,"}",i);
   int a = StringFind(json,"]",i);
   if(e < 0) e = INT_MAX;
   if(b > 0 && b < e) e = b;
   if(a > 0 && a < e) e = a;
   if(e == INT_MAX) return "";
   return StringSubstr(json,i,e-i);
}

double JsonDblVal(string json, string key) { return StringToDouble(JsonStrVal(json,key)); }

string JsonSubObj(string json, string key) {
   string k = "\"" + key + "\"";
   int p = StringFind(json,k);
   if(p < 0) return "";
   int i = p + StringLen(k);
   while(i < StringLen(json) && (json[i]==' ' || json[i]==':' || json[i]=='\t')) i++;
   if(i >= StringLen(json) || json[i]!='{') return "";
   int depth = 1;
   int j = i+1;
   while(j < StringLen(json) && depth > 0) {
      if(json[j]=='{') depth++;
      else if(json[j]=='}') depth--;
      j++;
   }
   return StringSubstr(json,i,j-i);
}

string JsonSubArr(string json, string key) {
   string k = "\"" + key + "\"";
   int p = StringFind(json,k);
   if(p < 0) return "";
   int i = p + StringLen(k);
   while(i < StringLen(json) && (json[i]==' ' || json[i]==':' || json[i]=='\t')) i++;
   if(i >= StringLen(json) || json[i]!='[') return "";
   int depth = 1;
   int j = i+1;
   while(j < StringLen(json) && depth > 0) {
      if(json[j]=='[') depth++;
      else if(json[j]==']') depth--;
      j++;
   }
   return StringSubstr(json,i,j-i);
}

string JsonArrItemObj(string arrJson, int idx) {
   if(StringLen(arrJson) < 2) return "";
   // skip opening [
   int i = 1;
   int curr = 0;
   while(i < StringLen(arrJson)) {
      while(i < StringLen(arrJson) && (arrJson[i]==' ' || arrJson[i]==',' || arrJson[i]=='\n' || arrJson[i]=='\r')) i++;
      if(i >= StringLen(arrJson) || arrJson[i]!='{') return "";
      int depth = 1;
      int j = i+1;
      while(j < StringLen(arrJson) && depth > 0) {
         if(arrJson[j]=='{') depth++;
         else if(arrJson[j]=='}') depth--;
         j++;
      }
      if(curr == idx) return StringSubstr(arrJson,i,j-i);
      i = j;
      curr++;
   }
   return "";
}

//+------------------------------------------------------------------+
//| UTIL: Pips                                                        |
//+------------------------------------------------------------------+
double PipSize(string sym) {
   double pt = SymbolInfoDouble(sym,SYMBOL_POINT);
   int dig = (int)SymbolInfoInteger(sym,SYMBOL_DIGITS);
   if(dig==5 || dig==3) return pt * 10.0;
   return pt;
}

double PriceToPips(string sym, double priceDiff) {
   double ps = PipSize(sym);
   if(ps == 0) return 0;
   return priceDiff / ps;
}

double PipsToPrice(string sym, double pips) {
   return pips * PipSize(sym);
}

//+------------------------------------------------------------------+
//| UTIL: Time / CET                                                  |
//+------------------------------------------------------------------+
datetime UtcNow() {
   return TimeGMT();
}

bool IsWithinCetTradingHours() {
   if(!InpUseTimeFilter) return true;
   datetime gm = TimeGMT();
   MqlDateTime dt;
   TimeToStruct(gm,dt);
   // CET = UTC+1 (winter), CEST = UTC+2 (summer)
   // Approximate: March last Sun to Oct last Sun = UTC+2
   bool isDST = false;
   int month = dt.mon;
   int day = dt.day;
   int dow = dt.day_of_week; // 0=Sun..6=Sat
   if(month > 3 && month < 10) isDST = true;
   else if(month == 3 && day >= 25) isDST = true;
   else if(month == 10 && day < 25) isDST = true;
   int cetHour = dt.hour + (isDST ? 2 : 1);
   if(cetHour >= 24) cetHour -= 24;
   return (cetHour >= InpTradeStartHour && cetHour < InpTradeEndHour);
}

datetime ParseIsoToUtc(string iso) {
   // Handles: 2026-04-27T22:30:00.000Z  or  2026-04-27T22:30:00+00:00
   if(StringLen(iso) < 19) return 0;
   int y = (int)StringToInteger(StringSubstr(iso,0,4));
   int m = (int)StringToInteger(StringSubstr(iso,5,2));
   int d = (int)StringToInteger(StringSubstr(iso,8,2));
   int h = (int)StringToInteger(StringSubstr(iso,11,2));
   int mn= (int)StringToInteger(StringSubstr(iso,14,2));
   int sc= (int)StringToInteger(StringSubstr(iso,17,2));
   // If string ends with Z it's already UTC — parse directly
   bool endsWithZ = (StringFind(iso,"Z") == StringLen(iso)-1);
   string fmt = StringFormat("%04d.%02d.%02d %02d:%02d:%02d",y,m,d,h,mn,sc);
   datetime dt = StringToTime(fmt);
   if(endsWithZ) return dt; // already UTC
   // Fallback: local parse + offset correction for non-Z strings
   int offsetSec = (int)(TimeCurrent() - TimeGMT());
   return dt + offsetSec;
}

//+------------------------------------------------------------------+
//| A) TREND CHECK — derived from recent_structure[0]                 |
//+------------------------------------------------------------------+
string GetRecentTrendDirection(string structJson) {
   string arr = structJson;
   if(StringLen(arr) < 5) return "";
   string item = JsonArrItemObj(arr,0); // most recent BOS/ChoCh
   if(StringLen(item)==0) return "";
   return JsonStrVal(item,"direction"); // "bullish" or "bearish"
}

bool CheckTrendMatch(EventData &ev) {
   bool isLong      = (ev.direction == "bullish");
   // PRIMARY: use trend_direction from webhook payload
   string trendDir  = ev.trend_dir;
   string source    = "webhook";
   // FALLBACK: parse from recent_structure array
   if(trendDir == "") {
      trendDir = GetRecentTrendDirection(ev.recent_struct_json);
      source = "recent_struct";
   }
   // REJECT if no trend data at all — we cannot evaluate without trend context
   if(trendDir == "") {
      LogMsg("TREND_REJ "+ev.symbol+" no_trend_data");
      return false;
   }
   bool trendBullish= (trendDir == "bullish");
   bool aligned     = (isLong == trendBullish);
   if(!aligned)
      LogMsg("TREND_REJ "+ev.symbol+" nowick="+ev.direction+" trend="+trendDir+" src="+source);
   else
      LogMsg("TREND_OK "+ev.symbol+" nowick="+ev.direction+" trend="+trendDir+" src="+source);
   return aligned;
}

//+------------------------------------------------------------------+
//| B) FVG CHECK                                                      |
//+------------------------------------------------------------------+
bool IsInsideZone(double price, double top, double btm) {
   if(top < btm) { double t=top; top=btm; btm=t; }
   return (price >= btm && price <= top);
}

bool CheckFvg(EventData &ev) {
   string sym = ev.symbol;
   bool isLong = (ev.direction == "bullish");

   // Determine trend (same priority as CheckTrendMatch)
   string trendDir = ev.trend_dir;
   if(trendDir == "") trendDir = GetRecentTrendDirection(ev.recent_struct_json);
   bool hasTrendData = (StringLen(trendDir) > 0);
   bool trendBullish = (trendDir == "bullish");
   bool trendBearish = (trendDir == "bearish");

   double entryPrice = ev.entry_anchor;
   double pip = PipSize(sym);
   double proximityThresholdPips = 15.0; // "close to" = within 15 pips of zone edge

   // --- Gather FVGs ---
   // PRIMARY: embedded FVGs from webhook event payload (matches TradingView EXACTLY)
   string fvgData = "";
   string fvgSource = "cache";

   if(StringLen(ev.fvgs_json) >= 5) {
      string firstItem = JsonArrItemObj(ev.fvgs_json, 0);
      if(StringLen(firstItem) > 0) {
         // Detect format: symbol-wrapped {"symbol":"X","zones":[...]} vs raw zones [{"direction":"..."}]
         if(JsonStrVal(firstItem, "symbol") != "") {
            // Symbol-wrapped format: find our symbol and extract zones
            for(int k=0; k<20; k++) {
               string entry = JsonArrItemObj(ev.fvgs_json, k);
               if(StringLen(entry)==0) break;
               if(JsonStrVal(entry, "symbol") == sym) {
                  fvgData = JsonSubArr(entry, "zones");
                  fvgSource = "event_wrapped";
                  break;
               }
            }
         }
         else {
            // Raw zones format: array of zone objects directly
            fvgData = ev.fvgs_json;
            fvgSource = "event_raw";
         }
      }
   }

   // SECONDARY: server cache from /api/fvg-periodic-updates
   if(StringLen(fvgData) < 5 && StringLen(g_cachedFvgState) > 10) {
      string fvgArr = JsonSubArr(g_cachedFvgState,"fvgs");
      if(StringLen(fvgArr) >= 3) {
         for(int i=0;i<20;i++) {
            string entry = JsonArrItemObj(fvgArr,i);
            if(StringLen(entry)==0) break;
            if(JsonStrVal(entry,"symbol") == sym) {
               string zones = JsonSubArr(entry,"zones");
               if(StringLen(zones)>=3) {
                  fvgData = zones;
                  fvgSource = "cache";
                  break;
               }
            }
         }
      }
   }

   if(StringLen(fvgData) < 5) {
      LogMsg("FVG_REJ "+sym+" no_FVG_data — cannot evaluate");
      return false;   // MANDATORY: reject when no FVG context
   }
   LogMsg("FVG_EVAL "+sym+" source="+fvgSource+" dataLen="+IntegerToString(StringLen(fvgData)));

   // --- Evaluate each FVG against the 6 rules ---
   for(int i=0;i<30;i++) {
      string fvg = JsonArrItemObj(fvgData,i);
      if(StringLen(fvg)==0) break;

      string state = JsonStrVal(fvg,"state");
      if(state == "invalidated") {
         LogMsg("FVG_SKIP_INVALIDATED "+sym+" slot="+JsonStrVal(fvg,"slot"));
         continue;
      }
      if(state != "active" && state != "mitigated") continue;

      string fvgDir = JsonStrVal(fvg,"direction");
      double ztop = JsonDblVal(fvg,"zone_top");
      double zbtm = JsonDblVal(fvg,"zone_bottom");
      if(ztop==0 && zbtm==0) continue;

      double zoneLow  = MathMin(ztop,zbtm);
      double zoneHigh = MathMax(ztop,zbtm);
      double zoneHeight = zoneHigh - zoneLow;
      double proxDist = MathMax(proximityThresholdPips * pip, zoneHeight * 0.5);

      bool inside     = (entryPrice >= zoneLow && entryPrice <= zoneHigh);
      bool closeAbove = (entryPrice > zoneHigh && entryPrice <= zoneHigh + proxDist);
      bool closeBelow = (entryPrice < zoneLow  && entryPrice >= zoneLow  - proxDist);
      bool closeTo    = closeAbove || closeBelow;

      if(hasTrendData) {
         // ==========================================================
         // RULES 1-3: BULLISH TREND
         // ==========================================================
         if(trendBullish) {
            if(isLong) {
               if(fvgDir == "bullish") {
                  if(inside) {
                     LogMsg("FVG_OK "+sym+" RULE=JUMPPAD (inside bullish FVG, bullish trend, long)");
                     continue;
                  }
               }
               else if(fvgDir == "bearish") {
                  if(inside) {
                     LogMsg("FVG_REJ "+sym+" RULE=BLOCK (inside bearish FVG, bullish trend, long)");
                     return false;
                  }
                  if(closeTo) {
                     LogMsg("FVG_OK "+sym+" RULE=DOL_MAGNET (close to bearish FVG, bullish trend, long)");
                     continue;
                  }
               }
            }
            else {
               // Safety net: short in bullish trend — block if inside bullish FVG
               if(fvgDir == "bullish" && inside) {
                  LogMsg("FVG_REJ "+sym+" RULE=BLOCK (inside bullish FVG, bullish trend, short)");
                  return false;
               }
            }
         }
         // ==========================================================
         // RULES 4-6: BEARISH TREND
         // ==========================================================
         else {
            if(!isLong) {
               if(fvgDir == "bearish") {
                  if(inside) {
                     LogMsg("FVG_OK "+sym+" RULE=PUSHDOWN (inside bearish FVG, bearish trend, short)");
                     continue;
                  }
               }
               else if(fvgDir == "bullish") {
                  if(inside) {
                     LogMsg("FVG_REJ "+sym+" RULE=BLOCK (inside bullish FVG, bearish trend, short)");
                     return false;
                  }
                  if(closeTo) {
                     LogMsg("FVG_OK "+sym+" RULE=DOL_MAGNET (close to bullish FVG, bearish trend, short)");
                     continue;
                  }
               }
            }
            else {
               // Safety net: long in bearish trend — block if inside bearish FVG
               if(fvgDir == "bearish" && inside) {
                  LogMsg("FVG_REJ "+sym+" RULE=BLOCK (inside bearish FVG, bearish trend, long)");
                  return false;
               }
            }
         }
      }
      else {
         // No trend data from structure → basic: reject if inside opposing FVG
         if(fvgDir == "bullish" && !isLong && inside) {
            LogMsg("FVG_REJ "+sym+" no-trend: inside bullish FVG but short");
            return false;
         }
         if(fvgDir == "bearish" && isLong && inside) {
            LogMsg("FVG_REJ "+sym+" no-trend: inside bearish FVG but long");
            return false;
         }
      }
   }
   LogMsg("FVG_OK "+sym+" no_active_zone_interaction");
   return true;
}

//+------------------------------------------------------------------+
//| C) NEWS CHECK                                                     |
//+------------------------------------------------------------------+
bool HasCurrencyInPair(string pair, string currency) {
   if(StringFind(pair,currency) >= 0) return true;
   return false;
}

bool CheckNewsOk(EventData &ev, bool isNewTrade=false) {
   if(StringLen(g_cachedNewsJson) < 10) return true;
   string arr = JsonSubArr(g_cachedNewsJson,"events");
   if(StringLen(arr) < 3) return true;
   datetime nowUtc = UtcNow();

   for(int i=0;i<50;i++) {
      string item = JsonArrItemObj(arr,i);
      if(StringLen(item)==0) break;
      string impactStr = JsonStrVal(item,"impact");
      int impact = (int)StringToInteger(impactStr);
      if(impactStr=="High") impact = 3;
      if(impact < 3) continue; // only red folder
      string cur = JsonStrVal(item,"currency");
      string utc = JsonStrVal(item,"utc_time");
      datetime newsUtc = ParseIsoToUtc(utc);
      if(newsUtc == 0) continue;
      int minsUntil = (int)((newsUtc - nowUtc)/60);

      // BEFORE: block upcoming news
      if(minsUntil >= 0 && minsUntil <= InpNewsBufferMin) {
         if(HasCurrencyInPair(ev.symbol,cur)) {
            LogMsg("NEWS_REJ "+ev.symbol+" "+cur+" news in "+IntegerToString(minsUntil)+"m");
            return false;
         }
         // Also check affected_pairs if provided
         string pairs = JsonStrVal(item,"affected_pairs");
         if(StringFind(pairs,ev.symbol) >= 0) {
            LogMsg("NEWS_REJ "+ev.symbol+" via affected_pairs in "+IntegerToString(minsUntil)+"m");
            return false;
         }
      }

      // AFTER: post-news cooldown (15min) — only block NEW trades, not existing positions
      if(isNewTrade && minsUntil < 0 && MathAbs(minsUntil) <= InpNewsExitMin) {
         if(HasCurrencyInPair(ev.symbol,cur)) {
            LogMsg("NEWS_COOLDOWN "+ev.symbol+" blocked "+IntegerToString(MathAbs(minsUntil))+"m after news");
            return false;
         }
         string pairs = JsonStrVal(item,"affected_pairs");
         if(StringFind(pairs,ev.symbol) >= 0) {
            LogMsg("NEWS_COOLDOWN "+ev.symbol+" via affected_pairs "+IntegerToString(MathAbs(minsUntil))+"m after");
            return false;
         }
      }
   }
   LogMsg("NEWS_OK "+ev.symbol);
   return true;
}

//+------------------------------------------------------------------+
//| D) TIME CHECK                                                     |
//+------------------------------------------------------------------+
// Helper: Determine if Berlin is in DST (last Sun Mar -> last Sun Oct)
bool IsBerlinDST(datetime gmt) {
   MqlDateTime dt;
   TimeToStruct(gmt, dt);
   int year = dt.year;
   // Last Sunday in March @ 01:00 UTC
   datetime dstStart = StringToTime(StringFormat("%04d.03.31 01:00", year));
   MqlDateTime tmp;
   while(true) {
      TimeToStruct(dstStart, tmp);
      if(tmp.day_of_week == 0) break;
      dstStart -= 86400;
   }
   // Last Sunday in October @ 01:00 UTC
   datetime dstEnd = StringToTime(StringFormat("%04d.10.31 01:00", year));
   while(true) {
      TimeToStruct(dstEnd, tmp);
      if(tmp.day_of_week == 0) break;
      dstEnd -= 86400;
   }
   return (gmt >= dstStart && gmt < dstEnd);
}

bool CheckTimeOk(EventData &ev) {
   if(!InpUseTimeFilter) return true;
   datetime gmt = TimeGMT();
   bool dst = IsBerlinDST(gmt);
   datetime berlin = gmt + (dst ? 7200 : 3600);
   MqlDateTime dt;
   TimeToStruct(berlin, dt);
   int hour = dt.hour;
   if(hour >= InpTradeStartHour && hour < InpTradeEndHour) {
      LogMsg("TIME_OK "+ev.symbol+" BERLIN hour="+IntegerToString(hour)+" DST="+(dst?"CEST":"CET"));
      return true;
   }
   LogMsg("TIME_REJ "+ev.symbol+" BERLIN hour="+IntegerToString(hour)+" outside "+IntegerToString(InpTradeStartHour)+"-"+IntegerToString(InpTradeEndHour)+" DST="+(dst?"CEST":"CET"));
   return false;
}

//+------------------------------------------------------------------+
//| FALLBACK: scan recent_structure for closer valid SL             |
//+------------------------------------------------------------------+
bool ScanRecentStructureForSL(string sym, bool isLong, double entryPrice,
                               string structJson, double &outSL) {
   int digits = (int)SymbolInfoInteger(sym,SYMBOL_DIGITS);
   double pip = PipSize(sym);
   if(pip == 0) return false;
   double bestSL = 0;
   double bestDist = 999999;

   string arr = structJson;
   if(StringLen(arr) < 3) return false;

   for(int i=0; i<10; i++) {
      string item = JsonArrItemObj(arr,i);
      if(StringLen(item)==0) break;

      string dir = JsonStrVal(item,"direction");
      double level = JsonDblVal(item,"break_level");
      if(level == 0) continue;

      // For LONGS we need a LOW (bearish break = broke below a low)
      // For SHORTS we need a HIGH (bullish break = broke above a high)
      bool isUseful = isLong ? (dir == "bearish") : (dir == "bullish");
      if(!isUseful) continue;

      double distPips = MathAbs(entryPrice - level) / pip;
      // Must be valid: >= min fallback AND <= max SL
      if(distPips < (double)InpFallbackMinPips) continue;
      if(distPips > (double)InpMaxSLPips) continue;
      // Pick closest to entry (tightest SL)
      if(distPips < bestDist) {
         bestDist = distPips;
         bestSL = level;
      }
   }

   if(bestSL != 0) {
      outSL = bestSL;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| F) SL CALCULATION                                                 |
//+------------------------------------------------------------------+
bool CalcSL(string sym, bool isLong, double entryPrice,
            int tfMin, double structHigh, double structLow,
            string recentStructJson,
            double &outSL, double &outEntry) {

   double pip = PipSize(sym);
   if(pip == 0) { LogMsg("ERR pip size zero"); return false; }
   int digits = (int)SymbolInfoInteger(sym,SYMBOL_DIGITS);

   // Use confirmed structure points from payload for all TFs
   double baseSL = isLong ? structLow : structHigh;
   if(baseSL == 0) { LogMsg("ERR no structure"); return false; }

   double rawDistPips = MathAbs(entryPrice - baseSL) / pip;
   LogMsg(sym+" tf="+IntegerToString(tfMin)+"m rawSL="+DoubleToString(rawDistPips,1)+"pips base="+DoubleToString(baseSL,digits));

   bool isMin15 = (tfMin >= 15);

   // 1) For 15M+: enforce 10p minimum. NO breathing. NO Devyy.
   if(isMin15 && rawDistPips < (double)InpMinSLPips) {
      outSL = isLong ? entryPrice - InpMinSLPips * pip
                     : entryPrice + InpMinSLPips * pip;
      outSL = NormalizeDouble(outSL,digits);
      outEntry = entryPrice;
      LogMsg(sym+" SL_FLOOR="+DoubleToString(InpMinSLPips,0)+"pips (15M+ min)");
      return true;
   }

   // 2) Breathing room (10%)
   double adjPips = rawDistPips * (1.0 + InpBreathingPct / 100.0);
   double adjSL   = isLong ? entryPrice - adjPips * pip
                           : entryPrice + adjPips * pip;
   adjSL = NormalizeDouble(adjSL,digits);

   LogMsg(sym+" SL_wBreath="+DoubleToString(adjPips,1)+"pips");

   // 3) Fallback if > 35 pips after breathing
   // Scan recent_structure history for a closer valid break level
   if(adjPips > (double)InpMaxSLPips) {
      LogMsg(sym+" SL_TOO_BIG -> scan recent_structure");
      double fallbackSL = 0;
      if(ScanRecentStructureForSL(sym,isLong,entryPrice,recentStructJson,fallbackSL)) {
         double fbPips = MathAbs(entryPrice - fallbackSL) / pip;
         if(fbPips >= (double)InpFallbackMinPips && fbPips <= (double)InpMaxSLPips) {
            double fbAdjPips = fbPips * (1.0 + InpBreathingPct / 100.0);
            outSL = isLong ? entryPrice - fbAdjPips * pip : entryPrice + fbAdjPips * pip;
            outSL = NormalizeDouble(outSL,digits);
            outEntry = entryPrice + (isLong ? InpDevyyEntryPips*pip : -InpDevyyEntryPips*pip);
            outEntry = NormalizeDouble(outEntry,digits);
            LogMsg(sym+" SL_struct_raw="+DoubleToString(fbPips,1)+" final="+DoubleToString(fbAdjPips,1));
            return true;
         }
      }
      LogMsg(sym+" SL_struct empty -> try 1m");
      double fallbackSL1m = 0;
      if(TryLowerTfSL(sym,isLong,entryPrice,"1minwebhook",fallbackSL1m)) {
         double fbPips = MathAbs(entryPrice - fallbackSL1m) / pip;
         if(fbPips >= (double)InpFallbackMinPips && fbPips <= (double)InpMaxSLPips) {
            double fbAdjPips = fbPips * (1.0 + InpBreathingPct / 100.0);
            outSL = isLong ? entryPrice - fbAdjPips * pip : entryPrice + fbAdjPips * pip;
            outSL = NormalizeDouble(outSL,digits);
            outEntry = entryPrice + (isLong ? InpDevyyEntryPips*pip : -InpDevyyEntryPips*pip);
            outEntry = NormalizeDouble(outEntry,digits);
            LogMsg(sym+" SL_1m_raw="+DoubleToString(fbPips,1)+" final="+DoubleToString(fbAdjPips,1));
            return true;
         }
      }
      LogMsg(sym+" SL_REJ no valid structure in history or 1m");
      return false;
   }

   outSL = adjSL;

   // Devyy Entry: ONLY when NATURAL (raw) SL > 10 pips
   // (Raw <= 10 was already handled above for 15M+, and on 1M we always allow Devyy)
   if(rawDistPips > (double)InpMinSLPips) {
      outEntry = entryPrice + (isLong ? InpDevyyEntryPips*pip : -InpDevyyEntryPips*pip);
      LogMsg(sym+" DevyyEntry="+DoubleToString(outEntry,digits));
   } else {
      outEntry = entryPrice;
      LogMsg(sym+" NoDevyy (rawSL="+DoubleToString(rawDistPips,1)+"pips <= 10)");
   }
   outEntry = NormalizeDouble(outEntry,digits);
   LogMsg(sym+" SL_OK="+DoubleToString(adjPips,1)+"pips final_entry="+DoubleToString(outEntry,digits));
   return true;
}

//+------------------------------------------------------------------+
//| FALLBACK: try 5m / 1m structure for tighter SL                  |
//+------------------------------------------------------------------+
bool TryLowerTfSL(string sym, bool isLong, double entryPrice,
                  string endpoint, double &outSL) {
   string url = InpWebhookUrl + "/api/" + endpoint;
   string resp;
   int code = HttpGet(url,resp);
   if(code != 200) { LogMsg("HTTP_FAIL "+endpoint+" code="+IntegerToString(code)); return false; }

   string arr = JsonSubArr(resp,"events");
   if(StringLen(arr) < 3) { LogMsg(endpoint+" empty"); return false; }

   int digits = (int)SymbolInfoInteger(sym,SYMBOL_DIGITS);
   double bestSL = 0;
   double bestDist = 999999;

   for(int i=0;i<10;i++) {
      string item = JsonArrItemObj(arr,i);
      if(StringLen(item)==0) break;
      string symItem = JsonStrVal(item,"symbol");
      if(symItem != sym) continue;
      // Look in data.recent_structure or data fields
      string dataObj = JsonSubObj(item,"data");
      if(StringLen(dataObj)==0) continue;
      double sh = JsonDblVal(dataObj,"latest_structure_high");
      double sl = JsonDblVal(dataObj,"latest_structure_low");
      if(sh==0 && sl==0) continue;
      double candidate = isLong ? sl : sh;
      if(candidate == 0) continue;
      double pip = PipSize(sym);
      double distPips = MathAbs(entryPrice - candidate) / pip;
      // Prefer closest but still <= 35 and >= 15
      if(distPips < (double)InpFallbackMinPips) continue;
      if(distPips > (double)InpMaxSLPips) continue;
      // Among valid ones, pick closest to entry (tightest)
      if(distPips < bestDist) {
         bestDist = distPips;
         bestSL = candidate;
      }
   }

   // TryLowerTfSL returns the RAW structure point (before breathing/Devyy).
   // Breathing and Devyy are applied in CalcSL after this returns.
   if(bestSL != 0) {
      outSL = bestSL;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| EXECUTE TRADE                                                     |
//+------------------------------------------------------------------+
void ExecuteTrade(EventData &ev) {
   string sym = ev.symbol;
   bool isLong = (ev.direction == "bullish");
   int digits = (int)SymbolInfoInteger(sym,SYMBOL_DIGITS);
   double pip = PipSize(sym);

   // Trend check A
   if(!CheckTrendMatch(ev)) return;
   // Global max positions guard
   if(CountPositions("") >= InpMaxPositions) {
      LogMsg("MAX_POS Reached "+IntegerToString(InpMaxPositions)+" — skipping "+ev.symbol);
      return;
   }
   // FVG check B
   if(!CheckFvg(ev)) return;
   // News check C
   if(!CheckNewsOk(ev, true)) return;
   // Time check D
   if(!CheckTimeOk(ev)) return;

   int posCount  = CountPositions(sym);
   int ordCount  = CountOrders(sym);

   // If we already have an open position, we STILL allow placing a NEW limit order
   // per plan: "if all rules align → we set a limit order on that as well"

   // If there are pending orders (and no position yet), replace them with new setup
   if(ordCount > 0 && posCount == 0) {
      LogMsg(sym+" REPLACING old pending order(s) with new NoWick setup");
      DeletePendingOrdersForSymbol(sym);
   }

   // If there are BOTH position AND pending orders, delete stale pending orders
   // and place fresh limit for this new setup (position stays open)
   if(ordCount > 0 && posCount > 0) {
      LogMsg(sym+" deleting stale pending order(s), keeping open position");
      DeletePendingOrdersForSymbol(sym);
   }

   // Entry from payload
   double rawEntry = ev.entry_anchor;
   double structH = ev.structure_high;
   double structL = ev.structure_low;

   // Calculate SL and adjusted entry
   double slPrice = 0;
   double entryPrice = 0;
   int tfMin = (int)StringToInteger(ev.timeframe);
   if(tfMin <= 0) tfMin = 15;
   if(!CalcSL(sym,isLong,rawEntry,tfMin,structH,structL,ev.recent_struct_json,slPrice,entryPrice)) return;

   // TP 1:1
   double slDist = MathAbs(entryPrice - slPrice);
   double tpPrice = isLong ? entryPrice + slDist * InpTPRatio
                           : entryPrice - slDist * InpTPRatio;
   tpPrice = NormalizeDouble(tpPrice,digits);

   // Lot size
   double lots = InpLotSize;
   if(InpMaxRiskPct > 0) lots = CalcRiskLot(sym,entryPrice,slPrice);
   double minLot = SymbolInfoDouble(sym,SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(sym,SYMBOL_VOLUME_MAX);
   double lotStep= SymbolInfoDouble(sym,SYMBOL_VOLUME_STEP);
   lots = MathFloor(lots/lotStep)*lotStep;
   lots = MathMax(minLot,MathMin(maxLot,lots));

   // Expiry
   datetime expiry = TimeCurrent() + tfMin * InpCandleExpiry * 60;

   // Place order
   ENUM_ORDER_TYPE otype = isLong ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT;
   MqlTradeRequest req={};
   MqlTradeResult res={};
   req.action = TRADE_ACTION_PENDING;
   req.symbol = sym;
   req.volume = lots;
   req.price  = entryPrice;
   req.sl     = slPrice;
   req.tp     = tpPrice;
   req.type   = otype;
   req.type_time = ORDER_TIME_SPECIFIED;
   req.expiration = expiry;
   req.deviation = 10;
   req.comment = "Devyyv4";

   if(!OrderSend(req,res)) {
      LogMsg("ORDER_FAIL "+sym+" err="+IntegerToString(GetLastError()));
      return;
   }
   if(res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED) {
      LogMsg("ORDER_OK "+sym+" "+(isLong?"BUY":"SELL")+" @"+DoubleToString(entryPrice,digits)+
             " SL="+DoubleToString(slPrice,digits)+" TP="+DoubleToString(tpPrice,digits)+
             " lots="+DoubleToString(lots,2));
      // Track pending
      int sz = ArraySize(g_pendingSetups);
      ArrayResize(g_pendingSetups,sz+1);
      g_pendingSetups[sz].orderTicket = res.order;
      g_pendingSetups[sz].symbol = sym;
      g_pendingSetups[sz].placeTime = TimeCurrent();
      g_pendingSetups[sz].tfMinutes = tfMin;
      g_pendingSetups[sz].eventReceivedAt = ev.received_at;
      g_pendingSetups[sz].direction = ev.direction;
      g_pendingSetups[sz].entryAnchor = ev.entry_anchor;
      g_pendingSetups[sz].recentStructJson = ev.recent_struct_json;
      g_pendingSetups[sz].fvgsJson = ev.fvgs_json;
   } else {
      LogMsg("ORDER_RETCODE "+sym+" "+IntegerToString(res.retcode));
   }
}

//+------------------------------------------------------------------+
//| LOT SIZE FROM RISK %                                              |
//+------------------------------------------------------------------+
double CalcRiskLot(string sym, double entry, double sl) {
   double riskAmt = AccountInfoDouble(ACCOUNT_BALANCE) * (InpMaxRiskPct/100.0);
   double tickSize = SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_SIZE);
   double tickVal = SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_VALUE);
   double dist = MathAbs(entry - sl);
   double ticksAtRisk = dist / tickSize;
   if(ticksAtRisk == 0 || tickVal == 0) return InpLotSize;
   double lots = riskAmt / (ticksAtRisk * tickVal);
   return lots;
}

//+------------------------------------------------------------------+
//| POSITION / ORDER COUNTERS                                         |
//+------------------------------------------------------------------+
int CountPositions(string sym) {
   int cnt=0;
   for(int i=PositionsTotal()-1;i>=0;i--) {
      ulong t=PositionGetTicket(i);
      if(t<=0) continue;
      if(sym=="" || PositionGetString(POSITION_SYMBOL)==sym) cnt++;
   }
   return cnt;
}

int CountOrders(string sym) {
   int cnt=0;
   for(int i=OrdersTotal()-1;i>=0;i--) {
      ulong t=OrderGetTicket(i);
      if(t<=0) continue;
      if(sym=="" || OrderGetString(ORDER_SYMBOL)==sym) cnt++;
   }
   return cnt;
}

//+------------------------------------------------------------------+
//| DELETE ALL PENDING ORDERS FOR SYMBOL                              |
//+------------------------------------------------------------------+
void DeletePendingOrdersForSymbol(string sym) {
   for(int i=OrdersTotal()-1;i>=0;i--) {
      ulong t=OrderGetTicket(i);
      if(t<=0) continue;
      if(OrderGetString(ORDER_SYMBOL) == sym) {
         LogMsg(sym+" DEL_ORDER ticket="+IntegerToString(t)+" type="+
                IntegerToString((int)OrderGetInteger(ORDER_TYPE)));
         g_trade.OrderDelete(t);
      }
   }
}

//+------------------------------------------------------------------+
//| POLL EVENTS                                                       |
//+------------------------------------------------------------------+
void PollEvents() {
   if(TimeCurrent() - g_lastEventsPoll < InpPollIntervalSec) return;
   g_lastEventsPoll = TimeCurrent();

   string url = InpWebhookUrl + "/api/events";
   string resp;
   int code = HttpGet(url,resp);
   if(code != 200) { LogMsg("EVENTS_HTTP "+IntegerToString(code)); return; }

   string arr = JsonSubArr(resp,"events");
   if(StringLen(arr) < 3) { return; }

   // Process newest events first (they come first in the array from our API)
   for(int i=0;i<30;i++) {
      string item = JsonArrItemObj(arr,i);
      if(StringLen(item)==0) break;

      string rec = JsonStrVal(item,"received_at");
      if(StringLen(rec)==0) continue;
      if(StringLen(g_lastEventReceivedAt)>0 && rec <= g_lastEventReceivedAt) break; // already processed

      string src = JsonStrVal(item,"source");
      string evt = JsonStrVal(item,"event");
      if(src != "wickless" || evt != "wickless_signal") continue;

      EventData ev;
      ev.rawJson      = item;
      ev.received_at  = rec;
      ev.symbol       = JsonStrVal(item,"symbol");
      ev.timeframe    = JsonStrVal(item,"timeframe");

      // ONLY accept 15m No-Wick trade signals
      int eventTfMin = (int)StringToInteger(ev.timeframe);
      if(eventTfMin != 15 && ev.timeframe != "15m") {
         LogMsg("SKIP non-15m TF="+ev.timeframe+" — only 15m allowed");
         continue;
      }

      string dataObj  = JsonSubObj(item,"data");
      ev.direction    = JsonStrVal(dataObj,"direction");
      ev.entry_anchor = JsonDblVal(dataObj,"entry_anchor");
      ev.candle_high  = JsonDblVal(dataObj,"candle_high");
      ev.candle_low   = JsonDblVal(dataObj,"candle_low");
      ev.structure_high = JsonDblVal(dataObj,"latest_structure_high");
      ev.structure_low  = JsonDblVal(dataObj,"latest_structure_low");
      ev.trend_dir      = JsonStrVal(dataObj,"trend_direction");
      ev.recent_struct_json = JsonSubArr(dataObj,"recent_structure");
      ev.fvgs_json      = JsonSubArr(dataObj,"fvgs");

      // Skip stale events (> 5 min old) to avoid processing history on startup
      datetime eventUtc = ParseIsoToUtc(rec);
      if(eventUtc == 0 || eventUtc < UtcNow() - 300) {
         LogMsg("SKIP stale event recv="+rec);
         continue;
      }

      if(ev.symbol == "" || ev.direction == "") continue;
      if(!IsAllowedSymbol(ev.symbol)) {
         LogMsg("SKIP symbol not allowed: "+ev.symbol);
         continue;
      }

      LogMsg("NEW_EVENT "+ev.symbol+" "+ev.direction+" TF="+ev.timeframe+" recv="+rec);
      ExecuteTrade(ev);
   }

   // Update last processed timestamp from the first (newest) event
   string firstItem = JsonArrItemObj(arr,0);
   if(StringLen(firstItem)>0) {
      string newest = JsonStrVal(firstItem,"received_at");
      if(StringLen(newest)>0 && newest > g_lastEventReceivedAt)
         g_lastEventReceivedAt = newest;
   }
}

//+------------------------------------------------------------------+
//| POLL NEWS                                                         |
//+------------------------------------------------------------------+
void PollNews() {
   if(TimeCurrent() - g_lastNewsPoll < InpNewsPollMin * 60) return;
   g_lastNewsPoll = TimeCurrent();

   string url = InpWebhookUrl + "/api/news";
   string resp;
   int code = HttpGet(url,resp);
   if(code != 200) { LogMsg("NEWS_HTTP "+IntegerToString(code)); return; }
   g_cachedNewsJson = resp;
   LogMsg("NEWS_UPDATED cnt="+IntegerToString((int)JsonDblVal(resp,"count")));
}

//+------------------------------------------------------------------+
//| POLL FVG STATE                                                    |
//+------------------------------------------------------------------+
void PollFvgState() {
   if(TimeCurrent() - g_lastFvgPoll < 60) return; // poll every 60 seconds
   g_lastFvgPoll = TimeCurrent();

   string url = InpWebhookUrl + "/api/fvg-periodic-updates";
   string resp;
   int code = HttpGet(url,resp);
   if(code != 200) { LogMsg("FVG_HTTP "+IntegerToString(code)); return; }
   g_cachedFvgState = resp;
   LogMsg("FVG_UPDATED");
}

//+------------------------------------------------------------------+
//| MANAGE OPEN POSITIONS (breakeven, trail, news-exit)             |
//+------------------------------------------------------------------+
void ManagePositions() {
   datetime now = TimeCurrent();
   datetime nowUtc = UtcNow();

   // News exit
   if(InpAutoCloseNews && StringLen(g_cachedNewsJson) > 10) {
      string arr = JsonSubArr(g_cachedNewsJson,"events");
      for(int i=PositionsTotal()-1;i>=0;i--) {
         ulong t = PositionGetTicket(i);
         if(t<=0) continue;
         string sym = PositionGetString(POSITION_SYMBOL);
         // Check each news event
         for(int j=0;j<50;j++) {
            string item = JsonArrItemObj(arr,j);
            if(StringLen(item)==0) break;
            int impact = (int)StringToInteger(JsonStrVal(item,"impact"));
            if(impact < 3) continue;
            string cur = JsonStrVal(item,"currency");
            if(!HasCurrencyInPair(sym,cur)) continue;
            string utc = JsonStrVal(item,"utc_time");
            datetime newsUtc = ParseIsoToUtc(utc);
            if(newsUtc == 0) continue;
            int minsUntil = (int)((newsUtc - nowUtc)/60);
            if(minsUntil >= 0 && minsUntil <= InpNewsExitMin) {
               LogMsg("NEWS_EXIT "+sym+" close before news "+IntegerToString(minsUntil)+"m");
               g_trade.PositionClose(t);
               break;
            }
         }
      }
   }

   // Breakeven after 1R
   for(int i=PositionsTotal()-1;i>=0;i--) {
      ulong t = PositionGetTicket(i);
      if(t<=0) continue;
      if(!PositionSelectByTicket(t)) continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openP = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      if(sl==0) continue;
      double risk  = MathAbs(openP - sl);
      if(risk == 0) continue;
      double curr  = (ptype==POSITION_TYPE_BUY) ? SymbolInfoDouble(sym,SYMBOL_BID)
                                                  : SymbolInfoDouble(sym,SYMBOL_ASK);
      double profit = (ptype==POSITION_TYPE_BUY) ? (curr - openP) : (openP - curr);
      if(profit >= risk) {
         double be = (ptype==POSITION_TYPE_BUY) ? openP + PipSize(sym) : openP - PipSize(sym);
         be = NormalizeDouble(be,(int)SymbolInfoInteger(sym,SYMBOL_DIGITS));
         if((ptype==POSITION_TYPE_BUY && sl < be) || (ptype==POSITION_TYPE_SELL && sl > be)) {
            MqlTradeRequest req={};
            MqlTradeResult res={};
            req.action = TRADE_ACTION_SLTP;
            req.position = t;
            req.sl = be;
            req.tp = tp;
            if(OrderSend(req,res)) {
               if(res.retcode == TRADE_RETCODE_DONE)
                  LogMsg("BE "+sym+" ticket="+IntegerToString(t));
            }
         }
      }
   }

   // Expired limit orders
   for(int i=OrdersTotal()-1;i>=0;i--) {
      ulong t = OrderGetTicket(i);
      if(t<=0) continue;
      datetime exp = (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);
      if(exp > 0 && now >= exp) {
         LogMsg("EXP_DEL "+OrderGetString(ORDER_SYMBOL)+" ticket="+IntegerToString(t));
         g_trade.OrderDelete(t);
      }
   }
}

//+------------------------------------------------------------------+
//| RE-EVALUATE PENDING ORDERS WHEN NEW FVG DATA ARRIVES            |
//+------------------------------------------------------------------+
void ReevaluatePendingOrders() {
   for(int i=ArraySize(g_pendingSetups)-1; i>=0; i--) {
      PendingSetup setup = g_pendingSetups[i];
      // Check if order still exists
      bool found = false;
      for(int j=OrdersTotal()-1; j>=0; j--) {
         ulong t = OrderGetTicket(j);
         if(t == setup.orderTicket) { found = true; break; }
      }
      if(!found) {
         // Already filled or cancelled; remove from tracking
         ArrayRemove(g_pendingSetups, i, 1);
         continue;
      }

      // Reconstruct minimal EventData for FVG check
      EventData ev;
      ev.symbol = setup.symbol;
      ev.direction = setup.direction;
      ev.entry_anchor = setup.entryAnchor;
      ev.recent_struct_json = setup.recentStructJson;
      ev.fvgs_json = setup.fvgsJson;

      // Re-run FVG filter
      if(!CheckFvg(ev)) {
         LogMsg("FVG_INVALIDATED_DEL "+setup.symbol+" ticket="+IntegerToString(setup.orderTicket)
                +" dir="+setup.direction+" entry="+DoubleToString(setup.entryAnchor,5));
         g_trade.OrderDelete(setup.orderTicket);
         ArrayRemove(g_pendingSetups, i, 1);
      }
   }
}

//+------------------------------------------------------------------+
//| SYMBOL ALLOWED?                                                   |
//+------------------------------------------------------------------+
bool IsAllowedSymbol(string sym) {
   if(StringFind(InpAllowedSymbols,sym) >= 0) return true;
   // Also check with + suffix (broker variants like GBPUSD+)
   if(StringFind(InpAllowedSymbols,sym+"+") >= 0) return true;
   return false;
}

//+------------------------------------------------------------------+
//| EVENT HANDLERS                                                    |
//+------------------------------------------------------------------+
int OnInit() {
   EventSetTimer(InpPollIntervalSec);
   g_trade.SetExpertMagicNumber(240427);
   g_trade.SetDeviationInPoints(10);
   g_trade.SetTypeFilling(ORDER_FILLING_IOC);
   g_trade.SetAsyncMode(false);
   // Set initial timestamp to now so we only process NEW webhooks
   g_lastEventReceivedAt = TimeToString(TimeGMT(),TIME_DATE|TIME_SECONDS);
   StringReplace(g_lastEventReceivedAt,".","-");
   StringReplace(g_lastEventReceivedAt," ","T");
   g_lastEventReceivedAt = g_lastEventReceivedAt + ".000Z";
   LogMsg("=== DevyyTrades EA v4 INIT === url="+InpWebhookUrl);
   LogMsg("Allowed: "+InpAllowedSymbols);
   LogMsg("Starting from: "+g_lastEventReceivedAt);
   // Warm-up news poll + FVG poll
   PollNews();
   PollFvgState();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   EventKillTimer();
   LogMsg("=== EA DEINIT ===");
}

void OnTick() {
   ManagePositions();
}

void OnTimer() {
   PollNews();
   PollFvgState();
   ReevaluatePendingOrders();
   PollEvents();
   ManagePositions();
}
//+------------------------------------------------------------------+
