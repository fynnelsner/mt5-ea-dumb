//+------------------------------------------------------------------+
//|                                              TradeManager.mqh    |
//|                    Manages trade execution and monitoring        |
//+------------------------------------------------------------------+
#property copyright "DevyyTrades"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//+------------------------------------------------------------------+
//| Trade manager class                                              |
//+------------------------------------------------------------------+
class CTradeManager
{
private:
   CTrade               m_trade;
   CPositionInfo        m_position;
   COrderInfo           m_order;

   // Track active trades
   struct TradeTracker
   {
      ulong              ticket;
      string             symbol;
      datetime           entryTime;
      double             entryPrice;
      double             slPrice;
      double             tpPrice;
      double             initialRisk;
      bool               breakevenTriggered;
      bool               partialClosed;
   };

   TradeTracker         m_trades[];

   // Internal methods
   int                  FindTradeIndex(ulong ticket);
   void                 AddTrade(ulong ticket, string symbol, double entry,
                                  double sl, double tp);
   void                 RemoveTrade(ulong ticket);

public:
                        CTradeManager();
                       ~CTradeManager();

   // Initialization
   void                 SetMagicNumber(int magic);
   void                 SetSlippage(int points);

   // Order placement
   bool                 PlaceBuyLimit(string symbol, double volume, double price,
                                       double sl, double tp, datetime expiry);
   bool                 PlaceSellLimit(string symbol, double volume, double price,
                                        double sl, double tp, datetime expiry);
   bool                 PlaceBuyStop(string symbol, double volume, double price,
                                    double sl, double tp, datetime expiry);
   bool                 PlaceSellStop(string symbol, double volume, double price,
                                     double sl, double tp, datetime expiry);

   // Position management
   bool                 ClosePosition(ulong ticket);
   bool                 CloseAllPositions(string symbol = "");
   bool                 ModifySL(ulong ticket, double newSL);
   bool                 ModifyTP(ulong ticket, double newTP);
   bool                 PartialClose(ulong ticket, double percent);

   // Trade monitoring
   void                 MonitorTrades();
   void                 CheckBreakeven();
   void                 CheckTrailingStop();

   // Pending orders
   bool                 DeletePendingOrder(ulong ticket);
   void                 DeleteAllPendingOrders(string symbol = "");
   int                  CountPendingOrders(string symbol = "");

   // Info
   int                  GetOpenPositionCount(string symbol = "");
   double               GetOpenProfit(string symbol = "");
   bool                 IsSymbolInUse(string symbol);
};

//+------------------------------------------------------------------+
//| Constructor                                                        |
//+------------------------------------------------------------------+
CTradeManager::CTradeManager()
{
   ArrayResize(m_trades, 0);
}

//+------------------------------------------------------------------+
//| Destructor                                                         |
//+------------------------------------------------------------------+
CTradeManager::~CTradeManager()
{
   ArrayResize(m_trades, 0);
}

//+------------------------------------------------------------------+
//| Set magic number                                                   |
//+------------------------------------------------------------------+
void CTradeManager::SetMagicNumber(int magic)
{
   m_trade.SetExpertMagicNumber(magic);
}

//+------------------------------------------------------------------+
//| Set slippage                                                       |
//+------------------------------------------------------------------+
void CTradeManager::SetSlippage(int points)
{
   m_trade.SetDeviationInPoints(points);
}

//+------------------------------------------------------------------+
//| Place buy limit order                                              |
//+------------------------------------------------------------------+
bool CTradeManager::PlaceBuyLimit(string symbol, double volume, double price,
                                   double sl, double tp, datetime expiry)
{
   if(!m_trade.BuyLimit(volume, price, symbol, sl, tp, ORDER_TIME_SPECIFIED, expiry))
   {
      Print("BuyLimit failed: ", m_trade.ResultRetcodeDescription());
      return false;
   }

   ulong ticket = m_trade.ResultOrder();
   AddTrade(ticket, symbol, price, sl, tp);

   Print("BuyLimit placed: ", symbol, " @", price, " Ticket: ", ticket);
   return true;
}

//+------------------------------------------------------------------+
//| Place sell limit order                                             |
//+------------------------------------------------------------------+
bool CTradeManager::PlaceSellLimit(string symbol, double volume, double price,
                                    double sl, double tp, datetime expiry)
{
   if(!m_trade.SellLimit(volume, price, symbol, sl, tp, ORDER_TIME_SPECIFIED, expiry))
   {
      Print("SellLimit failed: ", m_trade.ResultRetcodeDescription());
      return false;
   }

   ulong ticket = m_trade.ResultOrder();
   AddTrade(ticket, symbol, price, sl, tp);

   Print("SellLimit placed: ", symbol, " @", price, " Ticket: ", ticket);
   return true;
}

//+------------------------------------------------------------------+
//| Place buy stop order                                               |
//+------------------------------------------------------------------+
bool CTradeManager::PlaceBuyStop(string symbol, double volume, double price,
                                  double sl, double tp, datetime expiry)
{
   if(!m_trade.BuyStop(volume, price, symbol, sl, tp, ORDER_TIME_SPECIFIED, expiry))
   {
      Print("BuyStop failed: ", m_trade.ResultRetcodeDescription());
      return false;
   }

   ulong ticket = m_trade.ResultOrder();
   AddTrade(ticket, symbol, price, sl, tp);

   return true;
}

//+------------------------------------------------------------------+
//| Place sell stop order                                              |
//+------------------------------------------------------------------+
bool CTradeManager::PlaceSellStop(string symbol, double volume, double price,
                                   double sl, double tp, datetime expiry)
{
   if(!m_trade.SellStop(volume, price, symbol, sl, tp, ORDER_TIME_SPECIFIED, expiry))
   {
      Print("SellStop failed: ", m_trade.ResultRetcodeDescription());
      return false;
   }

   ulong ticket = m_trade.ResultOrder();
   AddTrade(ticket, symbol, price, sl, tp);

   return true;
}

//+------------------------------------------------------------------+
//| Close position by ticket                                             |
//+------------------------------------------------------------------+
bool CTradeManager::ClosePosition(ulong ticket)
{
   if(!m_trade.PositionClose(ticket))
   {
      Print("PositionClose failed: ", m_trade.ResultRetcodeDescription());
      return false;
   }

   RemoveTrade(ticket);
   Print("Position closed: ", ticket);
   return true;
}

//+------------------------------------------------------------------+
//| Close all positions (optionally filtered by symbol)              |
//+------------------------------------------------------------------+
bool CTradeManager::CloseAllPositions(string symbol)
{
   bool result = true;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!m_position.SelectByIndex(i))
         continue;

      if(symbol != "" && m_position.Symbol() != symbol)
         continue;

      if(!ClosePosition(m_position.Ticket()))
         result = false;
   }

   return result;
}

//+------------------------------------------------------------------+
//| Modify stop loss                                                   |
//+------------------------------------------------------------------+
bool CTradeManager::ModifySL(ulong ticket, double newSL)
{
   if(!m_position.SelectByTicket(ticket))
      return false;

   double currentTP = m_position.TakeProfit();

   if(!m_trade.PositionModify(ticket, newSL, currentTP))
   {
      Print("ModifySL failed: ", m_trade.ResultRetcodeDescription());
      return false;
   }

   // Update tracker
   int idx = FindTradeIndex(ticket);
   if(idx != -1)
      m_trades[idx].slPrice = newSL;

   Print("SL modified for ", ticket, ": ", newSL);
   return true;
}

//+------------------------------------------------------------------+
//| Modify take profit                                                 |
//+------------------------------------------------------------------+
bool CTradeManager::ModifyTP(ulong ticket, double newTP)
{
   if(!m_position.SelectByTicket(ticket))
      return false;

   double currentSL = m_position.StopLoss();

   if(!m_trade.PositionModify(ticket, currentSL, newTP))
   {
      Print("ModifyTP failed: ", m_trade.ResultRetcodeDescription());
      return false;
   }

   int idx = FindTradeIndex(ticket);
   if(idx != -1)
      m_trades[idx].tpPrice = newTP;

   return true;
}

//+------------------------------------------------------------------+
//| Partial close                                                      |
//+------------------------------------------------------------------+
bool CTradeManager::PartialClose(ulong ticket, double percent)
{
   if(!m_position.SelectByTicket(ticket))
      return false;

   double currentVolume = m_position.Volume();
   double closeVolume = NormalizeDouble(currentVolume * percent / 100.0, 2);

   // Use PositionClosePartial if available
   if(!m_trade.PositionClosePartial(ticket, closeVolume))
   {
      Print("PartialClose failed: ", m_trade.ResultRetcodeDescription());
      return false;
   }

   int idx = FindTradeIndex(ticket);
   if(idx != -1)
      m_trades[idx].partialClosed = true;

   Print("Partial close: ", ticket, " ", percent, "% (", closeVolume, ")");
   return true;
}

//+------------------------------------------------------------------+
//| Monitor and manage open trades                                   |
//+------------------------------------------------------------------+
void CTradeManager::MonitorTrades()
{
   CheckBreakeven();
   CheckTrailingStop();

   // Clean up closed trades from tracker
   for(int i = ArraySize(m_trades) - 1; i >= 0; i--)
   {
      if(!m_position.SelectByTicket(m_trades[i].ticket))
      {
         // Position closed
         Print("Trade removed from tracker (closed): ", m_trades[i].ticket);
         RemoveTrade(m_trades[i].ticket);
      }
   }
}

//+------------------------------------------------------------------+
//| Check and move to breakeven                                      |
//+------------------------------------------------------------------+
void CTradeManager::CheckBreakeven()
{
   for(int i = 0; i < ArraySize(m_trades); i++)
   {
      if(m_trades[i].breakevenTriggered)
         continue;

      if(!m_position.SelectByTicket(m_trades[i].ticket))
         continue;

      double currentPrice = (m_position.PositionType() == POSITION_TYPE_BUY) ?
                               SymbolInfoDouble(m_position.Symbol(), SYMBOL_BID) :
                               SymbolInfoDouble(m_position.Symbol(), SYMBOL_ASK);

      double entryPrice = m_trades[i].entryPrice;
      double initialRisk = MathAbs(entryPrice - m_trades[i].slPrice);
      double currentProfit = (m_position.PositionType() == POSITION_TYPE_BUY) ?
                               (currentPrice - entryPrice) : (entryPrice - currentPrice);

      // Move to BE after 1R profit
      if(currentProfit >= initialRisk)
      {
         double point = SymbolInfoDouble(m_position.Symbol(), SYMBOL_POINT);
         double newSL = (m_position.PositionType() == POSITION_TYPE_BUY) ?
                         entryPrice + (2 * point) : entryPrice - (2 * point);

         if(ModifySL(m_trades[i].ticket, newSL))
         {
            m_trades[i].breakevenTriggered = true;
            Print("Moved to breakeven: ", m_trades[i].ticket);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Check and adjust trailing stop                                   |
//+------------------------------------------------------------------+
void CTradeManager::CheckTrailingStop()
{
   // Trailing stop logic - can be customized based on ATR or fixed points
   // For now, implemented in EA's ManageOpenPositions
}

//+------------------------------------------------------------------+
//| Delete pending order                                               |
//+------------------------------------------------------------------+
bool CTradeManager::DeletePendingOrder(ulong ticket)
{
   if(!m_trade.OrderDelete(ticket))
   {
      Print("OrderDelete failed: ", m_trade.ResultRetcodeDescription());
      return false;
   }

   Print("Pending order deleted: ", ticket);
   return true;
}

//+------------------------------------------------------------------+
//| Delete all pending orders                                          |
//+------------------------------------------------------------------+
void CTradeManager::DeleteAllPendingOrders(string symbol)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;

      if(symbol != "" && OrderGetString(ORDER_SYMBOL) != symbol)
         continue;

      DeletePendingOrder(ticket);
   }
}

//+------------------------------------------------------------------+
//| Count pending orders                                               |
//+------------------------------------------------------------------+
int CTradeManager::CountPendingOrders(string symbol)
{
   int count = 0;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;

      if(symbol != "" && OrderGetString(ORDER_SYMBOL) != symbol)
         continue;

      count++;
   }

   return count;
}

//+------------------------------------------------------------------+
//| Get count of open positions                                        |
//+------------------------------------------------------------------+
int CTradeManager::GetOpenPositionCount(string symbol)
{
   int count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!m_position.SelectByIndex(i))
         continue;

      if(symbol != "" && m_position.Symbol() != symbol)
         continue;

      count++;
   }

   return count;
}

//+------------------------------------------------------------------+
//| Get open profit for symbol                                         |
//+------------------------------------------------------------------+
double CTradeManager::GetOpenProfit(string symbol)
{
   double profit = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!m_position.SelectByIndex(i))
         continue;

      if(symbol != "" && m_position.Symbol() != symbol)
         continue;

      profit += m_position.Profit() + m_position.Commission() + m_position.Swap();
   }

   return profit;
}

//+------------------------------------------------------------------+
//| Check if symbol has active position                              |
//+------------------------------------------------------------------+
bool CTradeManager::IsSymbolInUse(string symbol)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!m_position.SelectByIndex(i))
         continue;

      if(m_position.Symbol() == symbol)
         return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Find trade index in tracker                                        |
//+------------------------------------------------------------------+
int CTradeManager::FindTradeIndex(ulong ticket)
{
   for(int i = 0; i < ArraySize(m_trades); i++)
   {
      if(m_trades[i].ticket == ticket)
         return i;
   }
   return -1;
}

//+------------------------------------------------------------------+
//| Add trade to tracker                                             |
//+------------------------------------------------------------------+
void CTradeManager::AddTrade(ulong ticket, string symbol, double entry,
                              double sl, double tp)
{
   int idx = ArraySize(m_trades);
   ArrayResize(m_trades, idx + 1);

   m_trades[idx].ticket = ticket;
   m_trades[idx].symbol = symbol;
   m_trades[idx].entryPrice = entry;
   m_trades[idx].slPrice = sl;
   m_trades[idx].tpPrice = tp;
   m_trades[idx].entryTime = TimeCurrent();
   m_trades[idx].initialRisk = MathAbs(entry - sl);
   m_trades[idx].breakevenTriggered = false;
   m_trades[idx].partialClosed = false;
}

//+------------------------------------------------------------------+
//| Remove trade from tracker                                        |
//+------------------------------------------------------------------+
void CTradeManager::RemoveTrade(ulong ticket)
{
   int idx = FindTradeIndex(ticket);
   if(idx == -1)
      return;

   for(int i = idx; i < ArraySize(m_trades) - 1; i++)
      m_trades[i] = m_trades[i+1];

   ArrayResize(m_trades, ArraySize(m_trades) - 1);
}
//+------------------------------------------------------------------+
