//+------------------------------------------------------------------+
//|                                            SignalValidator.mqh   |
//|                 Validates trading signals against all conditions |
//+------------------------------------------------------------------+
#property copyright "DevyyTrades"
#property strict

//--- Structures for storing indicator state
struct TrendState
{
   string               symbol;
   bool                 isBullish;
   datetime             lastUpdate;
   double               swingHigh;
   double               swingLow;
   bool                 hasBOS;         // Break of Structure
   bool                 hasChoCh;         // Change of Character
};

struct FVGLevel
{
   string               symbol;
   string               timeframe;      // "4H", "DAILY"
   double               top;
   double               bottom;
   bool                 isBullish;
   datetime             lastUpdate;
   bool                 isActive;
};

struct NewsBlock
{
   string               symbol;
   datetime             startTime;
   datetime             endTime;
   string               impact;
   bool                 isActive;
};

//+------------------------------------------------------------------+
//| Signal validator class                                           |
//+------------------------------------------------------------------+
class CSignalValidator
{
private:
   TrendState           m_trendStates[];
   FVGLevel             m_fvgLevels[];
   NewsBlock            m_newsBlocks[];
   int                  m_maxHistory;

   // Internal helpers
   int                  FindTrendState(string symbol);
   int                  FindFVGLevel(string symbol, string timeframe);
   int                  FindNewsBlock(string symbol);
   bool                 IsPriceWithinFVG(string symbol, double price, FVGLevel &fvg);
   bool                 IsFVGRespected(string symbol, bool isLong, FVGLevel &fvg);

public:
                        CSignalValidator();
                       ~CSignalValidator();

   // Trend validation
   void                 SetTrendDirection(string symbol, bool isBullish);
   void                 SetSwingPoints(string symbol, double swingLow, double swingHigh);
   bool                 IsTrendAligned(string symbol, bool isLong);
   bool                 IsBullishTrend(string symbol);

   // FVG validation
   void                 SetFVGLevels(string symbol, string timeframe,
                                      double top, double bottom, bool isBullish);
   bool                 IsFVGValidForEntry(string symbol, bool isLong);
   bool                 HasPriceClosedThroughFVG(string symbol, bool isLong);
   bool                 IsTradingAgainstImbalance(string symbol, bool isLong);

   // News validation
   void                 SetNewsBlock(string symbol, datetime start, datetime end);
   bool                 IsNewsBlocked(string symbol);
   bool                 IsNearNewsEvent(string symbol, int minutesBefore);

   // Swing point management
   double               GetRecentSwingLow(string symbol);
   double               GetRecentSwingHigh(string symbol);
   void                 UpdateSwingPointsFromMarket(string symbol);

   // Cleanup
   void                 CleanupOldData();
   void                 ClearSymbolData(string symbol);
};

//+------------------------------------------------------------------+
//| Constructor                                                        |
//+------------------------------------------------------------------+
CSignalValidator::CSignalValidator()
{
   m_maxHistory = 100; // Keep last 100 signals per type
   ArrayResize(m_trendStates, 0);
   ArrayResize(m_fvgLevels, 0);
   ArrayResize(m_newsBlocks, 0);
}

//+------------------------------------------------------------------+
//| Destructor                                                         |
//+------------------------------------------------------------------+
CSignalValidator::~CSignalValidator()
{
   // Cleanup handled automatically
}

//+------------------------------------------------------------------+
//| Set trend direction for symbol                                     |
//+------------------------------------------------------------------+
void CSignalValidator::SetTrendDirection(string symbol, bool isBullish)
{
   int idx = FindTrendState(symbol);

   if(idx == -1)
   {
      // Add new state
      int size = ArraySize(m_trendStates);
      ArrayResize(m_trendStates, size + 1);
      idx = size;
      m_trendStates[idx].symbol = symbol;
   }

   m_trendStates[idx].isBullish = isBullish;
   m_trendStates[idx].lastUpdate = TimeCurrent();

   Print("Trend set for ", symbol, ": ", isBullish ? "BULLISH" : "BEARISH");
}

//+------------------------------------------------------------------+
//| Set swing points for symbol                                        |
//+------------------------------------------------------------------+
void CSignalValidator::SetSwingPoints(string symbol, double swingLow, double swingHigh)
{
   int idx = FindTrendState(symbol);

   if(idx == -1)
   {
      SetTrendDirection(symbol, true); // Default to bullish
      idx = FindTrendState(symbol);
   }

   if(idx != -1)
   {
      m_trendStates[idx].swingLow = swingLow;
      m_trendStates[idx].swingHigh = swingHigh;
      Print("Swing points updated for ", symbol, " - High: ", swingHigh, " Low: ", swingLow);
   }
}

//+------------------------------------------------------------------+
//| Check if trend aligns with trade direction                         |
//+------------------------------------------------------------------+
bool CSignalValidator::IsTrendAligned(string symbol, bool isLong)
{
   int idx = FindTrendState(symbol);

   if(idx == -1)
   {
      Print("No trend data for ", symbol, " - assuming valid");
      return true; // Allow trade if no trend data yet
   }

   bool trendBullish = m_trendStates[idx].isBullish;

   // Longs need bullish trend, shorts need bearish trend
   bool aligned = (isLong == trendBullish);

   if(!aligned)
      Print("Trend not aligned - Trend: ", trendBullish ? "Bullish" : "Bearish",
            " Trade: ", isLong ? "Long" : "Short");

   return aligned;
}

//+------------------------------------------------------------------+
//| Check if current trend is bullish                                  |
//+------------------------------------------------------------------+
bool CSignalValidator::IsBullishTrend(string symbol)
{
   int idx = FindTrendState(symbol);
   if(idx == -1)
      return true; // Default to bullish

   return m_trendStates[idx].isBullish;
}

//+------------------------------------------------------------------+
//| Set FVG levels for symbol                                          |
//+------------------------------------------------------------------+
void CSignalValidator::SetFVGLevels(string symbol, string timeframe,
                                     double top, double bottom, bool isBullish)
{
   int idx = FindFVGLevel(symbol, timeframe);

   if(idx == -1)
   {
      int size = ArraySize(m_fvgLevels);
      ArrayResize(m_fvgLevels, size + 1);
      idx = size;
      m_fvgLevels[idx].symbol = symbol;
      m_fvgLevels[idx].timeframe = timeframe;
   }

   m_fvgLevels[idx].top = top;
   m_fvgLevels[idx].bottom = bottom;
   m_fvgLevels[idx].isBullish = isBullish;
   m_fvgLevels[idx].lastUpdate = TimeCurrent();
   m_fvgLevels[idx].isActive = true;

   Print("FVG set for ", symbol, " [", timeframe, "]: ",
         bottom, " - ", top, " (", isBullish ? "Bullish" : "Bearish", ")");
}

//+------------------------------------------------------------------+
//| Check if FVG conditions are valid for entry                        |
//+------------------------------------------------------------------+
bool CSignalValidator::IsFVGValidForEntry(string symbol, bool isLong)
{
   // Check 4H and Daily FVGs
   string timeframes[] = {"4H", "DAILY"};

   for(int i = 0; i < ArraySize(timeframes); i++)
   {
      int idx = FindFVGLevel(symbol, timeframes[i]);

      if(idx == -1 || !m_fvgLevels[idx].isActive)
         continue;

      FVGLevel fvg = m_fvgLevels[idx];
      double currentPrice = SymbolInfoDouble(symbol, SYMBOL_BID);

      // Rule: Don't trade against imbalances
      // For longs: don't enter if current price is below a bearish FVG
      // For shorts: don't enter if current price is above a bullish FVG

      if(isLong && !fvg.isBullish && currentPrice < fvg.bottom)
      {
         // We're below a bearish FVG (sell zone) - not good for longs
         Print("Long rejected: Below bearish FVG [", timeframes[i], "]");
         return false;
      }

      if(!isLong && fvg.isBullish && currentPrice > fvg.top)
      {
         // We're above a bullish FVG (buy zone) - not good for shorts
         Print("Short rejected: Above bullish FVG [", timeframes[i], "]");
         return false;
      }

      // Rule: Only enter after closing through FVG
      // Price should have closed above bullish FVG or below bearish FVG
      if(!IsFVGRespected(symbol, isLong, fvg))
      {
         Print("FVG not yet respected - waiting for close through [", timeframes[i], "]");
         return false;
      }
   }

   return true;
}

//+------------------------------------------------------------------+
//| Check if price has closed through FVG                              |
//+------------------------------------------------------------------+
bool CSignalValidator::IsFVGRespected(string symbol, bool isLong, FVGLevel &fvg)
{
   // Get last closed candle
   double close[];
   ArraySetAsSeries(close, true);

   int copied = CopyClose(symbol, PERIOD_M15, 1, 1, close);
   if(copied < 1)
      return false;

   double lastClose = close[0];

   if(fvg.isBullish)
   {
      // For bullish FVG, price should close above it for longs
      // Or close below it for shorts to be valid
      return isLong ? (lastClose > fvg.bottom) : (lastClose < fvg.top);
   }
   else
   {
      // For bearish FVG, price should close below it for shorts
      // Or close above it for longs to be valid
      return isLong ? (lastClose > fvg.top) : (lastClose < fvg.bottom);
   }
}

//+------------------------------------------------------------------+
//| Check if trading against imbalance                                 |
//+------------------------------------------------------------------+
bool CSignalValidator::IsTradingAgainstImbalance(string symbol, bool isLong)
{
   // Returns true if trade IS against imbalance (bad)
   return !IsFVGValidForEntry(symbol, isLong);
}

//+------------------------------------------------------------------+
//| Check if price has closed through FVG (forms new structure)        |
//+------------------------------------------------------------------+
bool CSignalValidator::HasPriceClosedThroughFVG(string symbol, bool isLong)
{
   // Similar to IsFVGRespected but checks for structure change
   string timeframes[] = {"4H", "DAILY"};

   for(int i = 0; i < ArraySize(timeframes); i++)
   {
      int idx = FindFVGLevel(symbol, timeframes[i]);
      if(idx == -1) continue;

      // Check if price closed through the FVG level
      if(IsFVGRespected(symbol, isLong, m_fvgLevels[idx]))
         return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Set news block period                                            |
//+------------------------------------------------------------------+
void CSignalValidator::SetNewsBlock(string symbol, datetime start, datetime end)
{
   int idx = FindNewsBlock(symbol);

   if(idx == -1)
   {
      int size = ArraySize(m_newsBlocks);
      ArrayResize(m_newsBlocks, size + 1);
      idx = size;
      m_newsBlocks[idx].symbol = symbol;
   }

   m_newsBlocks[idx].startTime = start;
   m_newsBlocks[idx].endTime = end;
   m_newsBlocks[idx].impact = "HIGH";
   m_newsBlocks[idx].isActive = true;

   Print("News block set for ", symbol, ": ", TimeToString(start), " - ", TimeToString(end));
}

//+------------------------------------------------------------------+
//| Check if symbol is currently news blocked                          |
//+------------------------------------------------------------------+
bool CSignalValidator::IsNewsBlocked(string symbol)
{
   datetime currentTime = TimeCurrent();

   int idx = FindNewsBlock(symbol);
   if(idx == -1)
      return false;

   NewsBlock block = m_newsBlocks[idx];

   if(!block.isActive)
      return false;

   // Check if within block period
   bool blocked = (currentTime >= block.startTime && currentTime <= block.endTime);

   if(blocked)
      Print("News block active for ", symbol);

   return blocked;
}

//+------------------------------------------------------------------+
//| Check if near news event                                           |
//+------------------------------------------------------------------+
bool CSignalValidator::IsNearNewsEvent(string symbol, int minutesBefore)
{
   datetime currentTime = TimeCurrent();
   int idx = FindNewsBlock(symbol);

   if(idx == -1)
      return false;

   datetime newsTime = m_newsBlocks[idx].startTime + (2 * 3600); // Adjust for 2h before offset
   datetime threshold = newsTime - (minutesBefore * 60);

   return (currentTime >= threshold && currentTime < newsTime);
}

//+------------------------------------------------------------------+
//| Get recent swing low                                               |
//+------------------------------------------------------------------+
double CSignalValidator::GetRecentSwingLow(string symbol)
{
   int idx = FindTrendState(symbol);
   if(idx != -1)
      return m_trendStates[idx].swingLow;

   return 0.0;
}

//+------------------------------------------------------------------+
//| Get recent swing high                                              |
//+------------------------------------------------------------------+
double CSignalValidator::GetRecentSwingHigh(string symbol)
{
   int idx = FindTrendState(symbol);
   if(idx != -1)
      return m_trendStates[idx].swingHigh;

   return 0.0;
}

//+------------------------------------------------------------------+
//| Update swing points from current market data                       |
//+------------------------------------------------------------------+
void CSignalValidator::UpdateSwingPointsFromMarket(string symbol)
{
   // Calculate recent swing points from price action
   // This is a backup if indicator data isn't available

   double highs[], lows[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);

   int period = PERIOD_M15;
   int lookback = 20;

   int copiedHighs = CopyHigh(symbol, period, 0, lookback, highs);
   int copiedLows = CopyLow(symbol, period, 0, lookback, lows);

   if(copiedHighs < lookback || copiedLows < lookback)
      return;

   // Find recent swing high and low
   double recentHigh = 0;
   double recentLow = DBL_MAX;

   for(int i = 1; i < lookback - 1; i++)
   {
      // Simple swing detection
      if(highs[i] > highs[i-1] && highs[i] > highs[i+1])
         recentHigh = MathMax(recentHigh, highs[i]);

      if(lows[i] < lows[i-1] && lows[i] < lows[i+1])
         recentLow = MathMin(recentLow, lows[i]);
   }

   if(recentHigh > 0 && recentLow < DBL_MAX)
   {
      SetSwingPoints(symbol, recentLow, recentHigh);
   }
}

//+------------------------------------------------------------------+
//| Find trend state index                                           |
//+------------------------------------------------------------------+
int CSignalValidator::FindTrendState(string symbol)
{
   for(int i = 0; i < ArraySize(m_trendStates); i++)
   {
      if(m_trendStates[i].symbol == symbol)
         return i;
   }
   return -1;
}

//+------------------------------------------------------------------+
//| Find FVG level index                                             |
//+------------------------------------------------------------------+
int CSignalValidator::FindFVGLevel(string symbol, string timeframe)
{
   for(int i = 0; i < ArraySize(m_fvgLevels); i++)
   {
      if(m_fvgLevels[i].symbol == symbol && m_fvgLevels[i].timeframe == timeframe)
         return i;
   }
   return -1;
}

//+------------------------------------------------------------------+
//| Find news block index                                            |
//+------------------------------------------------------------------+
int CSignalValidator::FindNewsBlock(string symbol)
{
   for(int i = 0; i < ArraySize(m_newsBlocks); i++)
   {
      if(m_newsBlocks[i].symbol == symbol)
         return i;
   }
   return -1;
}

//+------------------------------------------------------------------+
//| Cleanup old data                                                   |
//+------------------------------------------------------------------+
void CSignalValidator::CleanupOldData()
{
   datetime currentTime = TimeCurrent();
   int expirySeconds = 86400; // 24 hours

   // Clean trend states
   for(int i = ArraySize(m_trendStates) - 1; i >= 0; i--)
   {
      if(currentTime - m_trendStates[i].lastUpdate > expirySeconds)
      {
         // Remove old entry
         for(int j = i; j < ArraySize(m_trendStates) - 1; j++)
            m_trendStates[j] = m_trendStates[j+1];
         ArrayResize(m_trendStates, ArraySize(m_trendStates) - 1);
      }
   }

   // Clean FVG levels
   for(int i = ArraySize(m_fvgLevels) - 1; i >= 0; i--)
   {
      if(currentTime - m_fvgLevels[i].lastUpdate > expirySeconds)
      {
         m_fvgLevels[i].isActive = false;
      }
   }

   // Clean news blocks
   for(int i = ArraySize(m_newsBlocks) - 1; i >= 0; i--)
   {
      if(currentTime > m_newsBlocks[i].endTime + 3600) // 1 hour after end
      {
         for(int j = i; j < ArraySize(m_newsBlocks) - 1; j++)
            m_newsBlocks[j] = m_newsBlocks[j+1];
         ArrayResize(m_newsBlocks, ArraySize(m_newsBlocks) - 1);
      }
   }
}

//+------------------------------------------------------------------+
//| Clear all data for symbol                                        |
//+------------------------------------------------------------------+
void CSignalValidator::ClearSymbolData(string symbol)
{
   // Remove trend state
   int idx = FindTrendState(symbol);
   if(idx != -1)
   {
      for(int i = idx; i < ArraySize(m_trendStates) - 1; i++)
         m_trendStates[i] = m_trendStates[i+1];
      ArrayResize(m_trendStates, ArraySize(m_trendStates) - 1);
   }

   // Remove FVGs
   for(int i = ArraySize(m_fvgLevels) - 1; i >= 0; i--)
   {
      if(m_fvgLevels[i].symbol == symbol)
      {
         for(int j = i; j < ArraySize(m_fvgLevels) - 1; j++)
            m_fvgLevels[j] = m_fvgLevels[j+1];
         ArrayResize(m_fvgLevels, ArraySize(m_fvgLevels) - 1);
      }
   }

   // Remove news blocks
   idx = FindNewsBlock(symbol);
   if(idx != -1)
   {
      for(int i = idx; i < ArraySize(m_newsBlocks) - 1; i++)
         m_newsBlocks[i] = m_newsBlocks[i+1];
      ArrayResize(m_newsBlocks, ArraySize(m_newsBlocks) - 1);
   }
}
//+------------------------------------------------------------------+
