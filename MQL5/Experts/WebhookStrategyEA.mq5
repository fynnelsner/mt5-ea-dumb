//+------------------------------------------------------------------+
//|                                            WebhookStrategyEA.mq5 |
//|                        DevyyTrades Webhook Strategy Automation   |
//|                                                                  |
//+------------------------------------------------------------------+
#property copyright "DevyyTrades"
#property link      ""
#property version   "1.00"

#include <Trade\Trade.mqh>
#include <Arrays\ArrayLong.mqh>
#include "..\..\Include\WebhookHandler.mqh"
#include "..\..\Include\SignalValidator.mqh"
#include "..\..\Include\TradeManager.mqh"

//--- Input Parameters
input group "=== Trading Settings ==="
input double            InpLotSize = 0.1;           // Lot Size
input int               InpMaxSpread = 20;          // Max Spread (points)
input int               InpSlippage = 3;            // Slippage (points)
input int               InpLimitOrderExpiryHours = 2; // Limit Order Expiry (hours) - 2.5h default
input int               InpLimitExpiryMinutes = 30; // Additional minutes for 2.5h expiry

input group "=== Time Filters ==="
input bool              InpUseTimeFilter = true;    // Use Trading Hours Filter
input int               InpStartHour = 8;           // Start Hour (CET)
input int               InpEndHour = 22;            // End Hour (CET)
input bool              InpFilterAsianSession = true; // Filter Asian Session (2h before/after)
input int               InpAsianSessionStart = 23;  // Asian Session Start Hour (CET)
input int               InpAsianSessionEnd = 8;   // Asian Session End Hour (CET)

input group "=== Risk Management ==="
input double            InpMaxRiskPercent = 2.0;    // Max Risk Per Trade (%)
input int               InpMaxSlPips = 50;          // Max SL Distance (pips)
input int               InpMinSlPips = 5;           // Min SL Distance (pips)
input bool              InpUseFixedSL = false;      // Use Fixed SL Instead of Swing Points
input int               InpFixedSLPips = 20;          // Fixed SL (pips) if used

input group "=== Signal Validation ==="
input int               InpSignalExpirySeconds = 300; // Signal Validity (seconds)
input bool              InpRequireTrendConfirm = true; // Require Trend Confirmation
input bool              InpRequireFVGConfirm = true;   // Require FVG Confirmation
input bool              InpCheckNews = true;          // Check News Filter

input group "=== Webhook Settings ==="
input string            InpWebhookPort = "8080";      // Webhook Server Port
input string            InpWebhookAuth = "";        // Webhook Auth Token (optional)
input bool              InpLogSignals = true;         // Log All Signals

//--- Global Variables
CWebhookHandler*        g_webhookHandler;
CSignalValidator*       g_signalValidator;
CTradeManager*          g_tradeManager;
CTrade                  g_trade;

//--- Signal State
struct SignalState
{
   string               symbol;
   ENUM_ORDER_TYPE      orderType;
   double               entryPrice;
   double               slPrice;
   double               tpPrice;
   datetime             timestamp;
   bool                 isNoWick;
   bool                 trendBullish;
   bool                 fvgValid;
   double               fvgTop;
   double               fvgBottom;
   datetime             expiry;
   string               signalId;
   bool                 newsFiltered;
};

SignalState             g_currentSignal;
bool                    g_hasActiveSignal = false;
string                  g_activePositions[];

//--- Session times (CET to Server Time conversion)
datetime                g_sessionStart;
datetime                g_sessionEnd;
int                     g_serverOffset = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("=== DevyyTrades Webhook Strategy EA Initializing ===");

   // Initialize trade object
   g_trade.SetExpertMagicNumber(GenerateMagicNumber());
   g_trade.SetDeviationInPoints(InpSlippage);
   g_trade.SetTypeFilling(ORDER_FILLING_FOK);
   g_trade.SetAsyncMode(false);

   // Initialize modules
   g_webhookHandler = new CWebhookHandler();
   g_signalValidator = new CSignalValidator();
   g_tradeManager = new CTradeManager();

   // Calculate server time offset from CET
   g_serverOffset = GetServerTimeOffset();
   Print("Server time offset from CET: ", g_serverOffset, " hours");

   // Initialize webhook server
   if(!g_webhookHandler.Init(InpWebhookPort))
   {
      Print("Failed to initialize webhook handler");
      return INIT_FAILED;
   }

   Print("Webhook server listening on port: ", InpWebhookPort);
   Print("Max SL distance: ", InpMaxSlPips, " pips");
   Print("Trading hours: ", InpStartHour, ":00 - ", InpEndHour, ":00 CET");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("=== DevyyTrades Webhook Strategy EA Deinitializing ===");

   delete g_webhookHandler;
   delete g_signalValidator;
   delete g_tradeManager;

   // Close any pending limit orders
   DeleteAllPendingOrders();
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Check and process incoming webhook signals
   ProcessWebhooks();

   // Check existing positions and manage them
   ManageOpenPositions();

   // Check for expired limit orders
   CheckExpiredOrders();

   // Check if we need to exit before news
   if(InpCheckNews)
      CheckNewsExit();
}

//+------------------------------------------------------------------+
//| Process incoming webhook signals                                 |
//+------------------------------------------------------------------+
void ProcessWebhooks()
{
   WebhookData signal;

   // Check for new webhook signal
   if(g_webhookHandler.CheckForSignal(signal))
   {
      Print("Received webhook signal: ", signal.indicator, " Type: ", signal.signalType);

      // Log signal if enabled
      if(InpLogSignals)
         LogSignal(signal);

      // Process based on indicator type
      if(signal.indicator == "Wickless")
      {
         ProcessWicklessSignal(signal);
      }
      else if(signal.indicator == "FVG")
      {
         ProcessFVGSignal(signal);
      }
      else if(signal.indicator == "News")
      {
         ProcessNewsSignal(signal);
      }
   }
}

//+------------------------------------------------------------------+
//| Process Wickless indicator signal (NoWick candles, ChoCh, BOS)    |
//+------------------------------------------------------------------+
void ProcessWicklessSignal(WebhookData &signal)
{
   // Parse the signal data
   string signalType = signal.signalType; // "NOWICK_BULLISH", "NOWICK_BEARISH", "CHOCH_BULLISH", etc.
   string symbol = signal.symbol;

   // Validate symbol is in our allowed list
   if(!IsAllowedSymbol(symbol))
   {
      Print("Symbol ", symbol, " not in allowed pairs list");
      return;
   }

   // Check trading hours
   if(!IsWithinTradingHours())
   {
      Print("Signal received outside trading hours");
      return;
   }

   // Check Asian session filter
   if(InpFilterAsianSession && IsNearAsianSession())
   {
      Print("Signal received too close to Asian session - skipping");
      return;
   }

   // Process NoWick candle signal
   if(StringFind(signalType, "NOWICK") != -1)
   {
      ProcessNoWickSignal(signal);
   }
   // Process trend change signal (ChoCh/BOS)
   else if(StringFind(signalType, "CHOCH") != -1 || StringFind(signalType, "BOS") != -1)
   {
      ProcessTrendSignal(signal);
   }
}

//+------------------------------------------------------------------+
//| Process NoWick candle signal - Main entry trigger                  |
//+------------------------------------------------------------------+
void ProcessNoWickSignal(WebhookData &signal)
{
   // Determine direction
   bool isLong = (StringFind(signal.signalType, "BULLISH") != -1);

   // Check if we have valid trend confirmation
   if(InpRequireTrendConfirm && !g_signalValidator.IsTrendAligned(signal.symbol, isLong))
   {
      Print("NoWick signal but trend not aligned - waiting");
      return;
   }

   // Check FVG confirmation
   if(InpRequireFVGConfirm && !g_signalValidator.IsFVGValidForEntry(signal.symbol, isLong))
   {
      Print("NoWick signal but FVG conditions not met - waiting");
      return;
   }

   // Calculate entry price (open of NoWick candle)
   double entryPrice = isLong ? signal.low : signal.high;

   // Calculate SL based on recent swing point
   double slPrice = CalculateStopLoss(signal.symbol, isLong, signal.swingLow, signal.swingHigh);

   // Calculate TP (using 1:2 R:R as default, can be adjusted)
   double tpPrice = CalculateTakeProfit(entryPrice, slPrice, isLong);

   // Validate SL distance
   if(!IsValidStopDistance(signal.symbol, entryPrice, slPrice))
   {
      Print("SL distance invalid - skipping trade");
      return;
   }

   // Check if we already have a position on this symbol
   if(HasOpenPosition(signal.symbol))
   {
      Print("Already have position on ", signal.symbol, " - skipping");
      return;
   }

   // Check news filter
   if(InpCheckNews && g_signalValidator.IsNewsBlocked(signal.symbol))
   {
      Print("News block active for ", signal.symbol, " - skipping");
      return;
   }

   // Place limit order
   ENUM_ORDER_TYPE orderType = isLong ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT;
   datetime expiry = TimeCurrent() + (InpLimitOrderExpiryHours * 3600) + (InpLimitExpiryMinutes * 60);

   // Calculate lot size based on risk
   double lotSize = CalculateLotSize(signal.symbol, entryPrice, slPrice);

   // Place the order
   if(PlaceLimitOrder(signal.symbol, orderType, lotSize, entryPrice, slPrice, tpPrice, expiry))
   {
      Print("Limit order placed: ", signal.symbol, " ", isLong ? "BUY" : "SELL",
            " @", entryPrice, " SL:", slPrice, " TP:", tpPrice);
   }
}

//+------------------------------------------------------------------+
//| Process trend signal (ChoCh/BOS)                                   |
//+------------------------------------------------------------------+
void ProcessTrendSignal(WebhookData &signal)
{
   // Update trend state in validator
   bool isBullish = (StringFind(signal.signalType, "BULLISH") != -1);
   g_signalValidator.SetTrendDirection(signal.symbol, isBullish);

   // Store swing points for SL calculation
   g_signalValidator.SetSwingPoints(signal.symbol, signal.swingLow, signal.swingHigh);

   Print("Trend updated for ", signal.symbol, ": ", isBullish ? "BULLISH" : "BEARISH");
}

//+------------------------------------------------------------------+
//| Process FVG signal                                               |
//+------------------------------------------------------------------+
void ProcessFVGSignal(WebhookData &signal)
{
   // Parse FVG data
   string fvgType = signal.signalType; // "FVG_BULLISH_4H", "FVG_BEARISH_DAILY", etc.
   string timeframe = signal.timeframe; // "4H", "DAILY"

   bool isBullish = (StringFind(fvgType, "BULLISH") != -1);

   // Store FVG levels for validation
   g_signalValidator.SetFVGLevels(signal.symbol, timeframe,
                                   signal.fvgTop, signal.fvgBottom, isBullish);

   Print("FVG updated for ", signal.symbol, " [", timeframe, "]: ",
         isBullish ? "Bullish" : "Bearish", " ", signal.fvgTop, " - ", signal.fvgBottom);
}

//+------------------------------------------------------------------+
//| Process News signal                                              |
//+------------------------------------------------------------------+
void ProcessNewsSignal(WebhookData &signal)
{
   // Parse news data
   datetime newsTime = signal.newsTime;
   string impact = signal.newsImpact; // "HIGH", "MEDIUM", "LOW"

   // Only care about high impact (red folder) news
   if(impact == "HIGH")
   {
      // Set news block period (2 hours before to 30 min after)
      datetime blockStart = newsTime - (2 * 3600);
      datetime blockEnd = newsTime + (1800);

      g_signalValidator.SetNewsBlock(signal.symbol, blockStart, blockEnd);

      // Exit existing positions 15 min before news
      datetime exitTime = newsTime - (15 * 60);
      if(TimeCurrent() >= exitTime && TimeCurrent() < newsTime)
      {
         ClosePositionsBeforeNews(signal.symbol);
      }

      Print("High impact news scheduled for ", signal.symbol, " at ", TimeToString(newsTime));
   }
}

//+------------------------------------------------------------------+
//| Calculate stop loss based on swing points or structure             |
//+------------------------------------------------------------------+
double CalculateStopLoss(string symbol, bool isLong, double swingLow, double swingHigh)
{
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   int slDistancePips = 0;

   if(isLong)
   {
      // For longs, SL goes below swing low
      double slPrice = swingLow - (5 * point); // 5 points buffer

      // Calculate distance in pips
      double currentPrice = SymbolInfoDouble(symbol, SYMBOL_BID);
      slDistancePips = (int)((currentPrice - slPrice) / point / 10);

      // If distance too large, find alternative structure
      if(slDistancePips > InpMaxSlPips)
      {
         // Check 5min for closer swing point (would need additional indicator data)
         // For now, use ATR-based SL
         slPrice = currentPrice - (InpMaxSlPips * 10 * point);
      }

      return NormalizeDouble(slPrice, digits);
   }
   else
   {
      // For shorts, SL goes above swing high
      double slPrice = swingHigh + (5 * point); // 5 points buffer

      double currentPrice = SymbolInfoDouble(symbol, SYMBOL_ASK);
      slDistancePips = (int)((slPrice - currentPrice) / point / 10);

      if(slDistancePips > InpMaxSlPips)
      {
         slPrice = currentPrice + (InpMaxSlPips * 10 * point);
      }

      return NormalizeDouble(slPrice, digits);
   }
}

//+------------------------------------------------------------------+
//| Calculate take profit (1:2 R:R default)                            |
//+------------------------------------------------------------------+
double CalculateTakeProfit(double entryPrice, double slPrice, bool isLong)
{
   double risk = MathAbs(entryPrice - slPrice);
   double reward = risk * 2.0; // 1:2 risk:reward

   if(isLong)
      return entryPrice + reward;
   else
      return entryPrice - reward;
}

//+------------------------------------------------------------------+
//| Validate stop loss distance                                        |
//+------------------------------------------------------------------+
bool IsValidStopDistance(string symbol, double entryPrice, double slPrice)
{
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double distance = MathAbs(entryPrice - slPrice);
   int pips = (int)(distance / point / 10);

   if(pips > InpMaxSlPips)
   {
      Print("SL distance too large: ", pips, " pips (max: ", InpMaxSlPips, ")");
      return false;
   }

   if(pips < InpMinSlPips)
   {
      Print("SL distance too small: ", pips, " pips (min: ", InpMinSlPips, ")");
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk percentage                        |
//+------------------------------------------------------------------+
double CalculateLotSize(string symbol, double entryPrice, double slPrice)
{
   double riskAmount = AccountInfoDouble(ACCOUNT_BALANCE) * (InpMaxRiskPercent / 100.0);
   double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);

   double slDistance = MathAbs(entryPrice - slPrice);
   double ticksAtRisk = slDistance / tickSize;
   double lotSize = riskAmount / (ticksAtRisk * tickValue);

   // Normalize to symbol's lot step
   double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);

   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   lotSize = MathMax(minLot, MathMin(maxLot, lotSize));

   return lotSize;
}

//+------------------------------------------------------------------+
//| Place limit order                                                |
//+------------------------------------------------------------------+
bool PlaceLimitOrder(string symbol, ENUM_ORDER_TYPE type, double volume,
                     double price, double sl, double tp, datetime expiry)
{
   MqlTradeRequest request = {};
   MqlTradeResult result = {};

   request.action = TRADE_ACTION_PENDING;
   request.symbol = symbol;
   request.volume = volume;
   request.price = price;
   request.sl = sl;
   request.tp = tp;
   request.type = type;
   request.type_time = ORDER_TIME_SPECIFIED;
   request.expiration = expiry;
   request.deviation = InpSlippage;
   request.comment = "DevyyTrades Webhook";

   if(!OrderSend(request, result))
   {
      Print("OrderSend failed: ", GetLastError());
      return false;
   }

   return (result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED);
}

//+------------------------------------------------------------------+
//| Check if symbol is in allowed pairs list                           |
//+------------------------------------------------------------------+
bool IsAllowedSymbol(string symbol)
{
   string allowedSymbols[] = {"USDJPY", "GBPUSD", "AUDUSD", "XAUUSD"};

   for(int i = 0; i < ArraySize(allowedSymbols); i++)
   {
      if(symbol == allowedSymbols[i])
         return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Check if within trading hours (8AM-10PM CET)                       |
//+------------------------------------------------------------------+
bool IsWithinTradingHours()
{
   if(!InpUseTimeFilter)
      return true;

   // Convert server time to CET
   datetime serverTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(serverTime, dt);

   // Adjust to CET (server time - offset)
   int currentHour = (dt.hour - g_serverOffset + 24) % 24;

   // Check if within trading hours
   if(InpStartHour <= InpEndHour)
   {
      return (currentHour >= InpStartHour && currentHour < InpEndHour);
   }
   else
   {
      // Crosses midnight
      return (currentHour >= InpStartHour || currentHour < InpEndHour);
   }
}

//+------------------------------------------------------------------+
//| Check if near Asian session (2 hours before/after)                |
//+------------------------------------------------------------------+
bool IsNearAsianSession()
{
   datetime serverTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(serverTime, dt);

   int currentHour = (dt.hour - g_serverOffset + 24) % 24;
   int currentMinute = dt.min;

   // Asian session: 23:00 - 08:00 CET
   // Block: 21:00-23:00 and 08:00-10:00

   // Before Asian session (21:00 - 23:00)
   if(currentHour >= 21 && currentHour < 23)
      return true;

   // After Asian session open (08:00 - 10:00)
   if(currentHour >= 8 && currentHour < 10)
      return true;

   return false;
}

//+------------------------------------------------------------------+
//| Get server time offset from CET                                  |
//+------------------------------------------------------------------+
int GetServerTimeOffset()
{
   // Try to get from terminal settings
   int terminalOffset = (int)(TimeCurrent() - TimeGMT());

   // CET is UTC+1 (standard time) or UTC+2 during DST
   // This is a simplified calculation - you may need to adjust for DST
   int cetOffset = 1; // UTC+1

   return terminalOffset / 3600 - cetOffset;
}

//+------------------------------------------------------------------+
//| Check for open positions on symbol                               |
//+------------------------------------------------------------------+
bool HasOpenPosition(string symbol)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) == symbol)
         return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Manage open positions                                            |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   // Check for breakeven / trailing stop logic
   // This can be expanded based on your specific trade management rules

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0)
         continue;

      // Get position details
      string symbol = PositionGetString(POSITION_SYMBOL);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      // Breakeven logic: Move to BE after 1R profit
      double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
      double riskPips = MathAbs(openPrice - currentSL) / point / 10;
      double profitPips = 0;

      if(posType == POSITION_TYPE_BUY)
         profitPips = (SymbolInfoDouble(symbol, SYMBOL_BID) - openPrice) / point / 10;
      else
         profitPips = (openPrice - SymbolInfoDouble(symbol, SYMBOL_ASK)) / point / 10;

      // Move to breakeven after 1R
      if(profitPips >= riskPips && currentSL != openPrice)
      {
         // Add small buffer for BE
         double bePrice = (posType == POSITION_TYPE_BUY) ?
                          openPrice + (2 * point) : openPrice - (2 * point);

         ModifyPositionSL(ticket, bePrice);
      }
   }
}

//+------------------------------------------------------------------+
//| Modify position stop loss                                        |
//+------------------------------------------------------------------+
bool ModifyPositionSL(ulong ticket, double newSL)
{
   MqlTradeRequest request = {};
   MqlTradeResult result = {};

   request.action = TRADE_ACTION_SLTP;
   request.position = ticket;
   request.sl = newSL;

   return OrderSend(request, result);
}

//+------------------------------------------------------------------+
//| Check for expired limit orders                                   |
//+------------------------------------------------------------------+
void CheckExpiredOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket <= 0)
         continue;

      datetime expiry = (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);

      if(TimeCurrent() >= expiry)
      {
         // Order expired - delete it
         MqlTradeRequest request = {};
         MqlTradeResult result = {};

         request.action = TRADE_ACTION_REMOVE;
         request.order = ticket;

         OrderSend(request, result);

         Print("Expired order deleted: ", ticket);
      }
   }
}

//+------------------------------------------------------------------+
//| Check if we need to exit before news                             |
//+------------------------------------------------------------------+
void CheckNewsExit()
{
   // Implemented in ProcessNewsSignal - check every tick
   // This function can be expanded for additional logic
}

//+------------------------------------------------------------------+
//| Close positions before high impact news                          |
//+------------------------------------------------------------------+
void ClosePositionsBeforeNews(string symbol)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) == symbol)
      {
         g_trade.PositionClose(ticket);
         Print("Position closed before news: ", ticket, " Symbol: ", symbol);
      }
   }
}

//+------------------------------------------------------------------+
//| Delete all pending orders                                        |
//+------------------------------------------------------------------+
void DeleteAllPendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket <= 0)
         continue;

      MqlTradeRequest request = {};
      MqlTradeResult result = {};

      request.action = TRADE_ACTION_REMOVE;
      request.order = ticket;

      OrderSend(request, result);
   }
}

//+------------------------------------------------------------------+
//| Generate magic number                                            |
//+------------------------------------------------------------------+
int GenerateMagicNumber()
{
   return 1001; // You can make this dynamic
}

//+------------------------------------------------------------------+
//| Log signal to file                                               |
//+------------------------------------------------------------------+
void LogSignal(WebhookData &signal)
{
   string filename = "DevyyTrades_Signals_" + IntegerToString(TimeCurrent()) + ".csv";
   string data = TimeToString(TimeCurrent()) + ";" +
                 signal.indicator + ";" +
                 signal.symbol + ";" +
                 signal.signalType + ";" +
                 DoubleToString(signal.price) + "\n";

   // File writing would go here
}

//+------------------------------------------------------------------+
//| Timer function for webhook polling (if not using sockets)        |
//+------------------------------------------------------------------+
void OnTimer()
{
   // Alternative to OnTick for webhook checking
   // Can be used if socket-based approach isn't working
   ProcessWebhooks();
}
//+------------------------------------------------------------------+
