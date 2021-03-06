
#include <Trade\Trade.mqh>
#include <Trade\OrderInfo.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

#define NO_VALUE      INT_MAX                      // invalid value of Signal/Trend

//--- Channel parameters
input int             InpBBPeriod   =20;           // BBands period
input double          InpBBDeviation=2.0;          // BBands deviation
//-- MA periods
input int             InpFastEMA    =12;           // fast EMA period
input int             InpSlowEMA    =26;           // slow EMA period
//-- ATR parameters
input int             InpATRPeriod  =14;           // ATR period
input double          InpATRCoeff   =1.0;          // ATR coefficient to detect flat
//--- money management parameters
input double          InpLot        =0.1;          // lot
//--- timeframe parameters
input ENUM_TIMEFRAMES InpBBTF       =PERIOD_M15;   // BBands timeframe
input ENUM_TIMEFRAMES InpMATF       =PERIOD_M15;   // trend detection timeframe
//--- EA identifier for trade transactions
input long            InpMagicNumber=245600;       // Magic Number

//---  indicators handles
int    ExtBBHandle    =INVALID_HANDLE;
int    ExtFastMAHandle=INVALID_HANDLE;
int    ExtSlowMAHandle=INVALID_HANDLE;
int    ExtATRHandle   =INVALID_HANDLE;
//--- channel variables;
double ExtUpChannel   =0;
double ExtLowChannel  =0;
double ExtChannelRange=0;

int    ExtTrend=0;                                 // value 0 indicates there is "no trend"
bool   ExtInputsValidated=true;                    // check values of the inputs

//--- service objects
CTrade        ExtTrade;
COrderInfo    ExtOrderInfo;
CPositionInfo ExtPositionInfo;
CSymbolInfo   ExtSymbolInfo;
//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
//--- create the Bollinger Bands indicator handle
   ExtBBHandle=iBands(Symbol(), InpBBTF, InpBBPeriod, 0, InpBBDeviation, PRICE_CLOSE);
   if(ExtBBHandle==INVALID_HANDLE)
     {
      Print("Failed to create indicator iBands");
      return(INIT_FAILED);
     }
//--- create the fast EMA indicator handle
   ExtFastMAHandle=iMA(Symbol(), InpMATF, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   if(ExtFastMAHandle==INVALID_HANDLE)
     {
      Print("Failed to create fast MA indicator");
      return(INIT_FAILED);
     }
//--- create the fast EMA indicator handle
   ExtSlowMAHandle=iMA(Symbol(), InpMATF, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   if(ExtSlowMAHandle==INVALID_HANDLE)
     {
      Print("Failed to create slow MA indicator");
      return(INIT_FAILED);
     }
//--- create the ATR indicator handle
   ExtATRHandle=iATR(Symbol(), InpMATF, InpATRPeriod);
   if(ExtATRHandle==INVALID_HANDLE)
     {
      Print("Failed to create slow ATR indicator");
      return(INIT_FAILED);
     }
//--- check timeframes
   if(PeriodSeconds(InpBBTF)>PeriodSeconds(InpMATF))
     {
      //--- EMA timeframe must be equal to or higher than Bollinger timeframe
      Print("Error! PeriodSeconds(InpBBTF)>PeriodSeconds(InpMATF)");
      if(MQLInfoInteger(MQL_TESTER))
         ExtInputsValidated=false;
      else
         return(INIT_PARAMETERS_INCORRECT);
     }
//--- setup InpMagicNumber for trade operations
   ExtTrade.SetExpertMagicNumber(InpMagicNumber);
//--- success
   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
//--- release indicator handles
   IndicatorRelease(ExtBBHandle);
   IndicatorRelease(ExtFastMAHandle);
   IndicatorRelease(ExtSlowMAHandle);
  }
//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   static bool order_sent    =false;    // execution of order placing at the current bar failed
   static bool order_deleted =false;    // deletion of a limit order at the current bar failed
   static bool order_modified=false;    // deletion of a limit order at the current bar failed
//--- if input parameters are incorrect, testing should be stopped at the first tick
   if(!ExtInputsValidated)
      TesterStop();
//--- check if a new bar opens and if there is a trend
   if(IsNewBar(ExtTrend))
     {
      //--- reset all status variables
      order_sent    =false;
      order_deleted =false;
      order_modified=false;
     }
//--- create auxiliary variables to make the check only once
   bool order_exist   =OrderExist();
   bool trend_detected=TrendDetected(ExtTrend);
//--- if there is no trend or there is an open position, delete pending orders
   if(!trend_detected || PositionExist())
      if(!order_deleted)
        {
         order_deleted=DeleteLimitOrders();
         //--- if the orders have been successfully deleted, no other operations are needed at this bar
         if(order_deleted)
           {
            //--- forbid order sending and modification
            order_sent    =true;
            order_modified=true;
            return;
           }
        }

//--- there is trend
   if(trend_detected)
     {
      //--- if there is no order, set a limit order at the channel border
      if(!order_exist && !order_sent)
        {
         order_sent=SendLimitOrder(ExtTrend);
         if(order_sent)
            order_modified=true;
        }
      //--- if there is a limit order, try to move at to the current channel border
      if(order_exist && !order_modified)
         order_modified=ModifyLimitOrder(ExtTrend);
     }
//---
  }
//+------------------------------------------------------------------+
//|  Check if there is trend                                         |
//+------------------------------------------------------------------+
bool TrendDetected(int trend)
  {
   return(trend==1 || trend==-1);
  }
//+------------------------------------------------------------------+
//| Checks the emergence of a new bar on the current timeframe,      |
//| also calculates the trend and the signal                         |
//+------------------------------------------------------------------+
bool IsNewBar(int &trend)
  {
//--- stores the current bar opening time
   static datetime timeopen=0;
//--- get the current bar opening time
   datetime time=iTime(NULL, InpMATF, 0);
//--- if the time has not changed, the bar is not new
   if(time==timeopen)
      return(false);
//--- calculate the current trend
   trend=TrendCalculate();
//--- if the trend value could not be obtained, try again at the next call
   if(trend==NO_VALUE)
      return(false);
//--- all checks performed successfully: trend and new bar opening time received
   timeopen=time; //remember the bar opening time for further calls
//---
   return(true);
  }
//+------------------------------------------------------------------+
//| Returns 1 for UpTrend or -1 for DownTrend (0 = no trend)         |
//+------------------------------------------------------------------+
int TrendCalculate()
  {
//--- first check if we are in the range
   int is_range=IsRange();
//--- if the value could not be calculated
   if(is_range==NO_VALUE)
     {
      //--- the failed to check, early exit with the "no value" response
      return(NO_VALUE);
     }
//--- if the price is in a narrow range, the trend should not be calculated
   if(is_range==true) // narrow range, return "flat" (range)
      return(0);
//--- get the ATR value on the last completed bar
   double atr_buffer[];
   if(CopyBuffer(ExtBBHandle, 0, 1, 1, atr_buffer)==-1)
     {
      PrintFormat("%s: Failed CopyBuffer(ExtATRHandle,0,1,2,atr_buffer), code=%d", __FILE__, GetLastError());
      return(NO_VALUE);
     }
//--- get the fast MA value on the last completed bar
   double fastma_buffer[];
   if(CopyBuffer(ExtFastMAHandle, 0, 1, 1, fastma_buffer)==-1)
     {
      PrintFormat("%s: Failed CopyBuffer(ExtFastMAHandle,0,1,2,fastma_buffer), code=%d", __FILE__, GetLastError());
      return(NO_VALUE);
     }
//--- get the slow MA value on the last completed bar
   double slowma_buffer[];
   if(CopyBuffer(ExtSlowMAHandle, 0, 1, 1, slowma_buffer)==-1)
     {
      PrintFormat("%s: Failed CopyBuffer(ExtSlowMAHandle,0,1,2,slowma_buffer), code=%d", __FILE__, GetLastError());
      return(NO_VALUE);
     }
//--- trend is not detected
   int trend=0;
//--- if the price is above the MA
   if(fastma_buffer[0]>slowma_buffer[0])
      trend=1;   // uptrend
//--- if the price is below the MA
   if(fastma_buffer[0]<slowma_buffer[0])
      trend=-1;  // downtrend
//--- return the trend direction
   return(trend);
  }
//+------------------------------------------------------------------+
//|  Returns true if the channel is narrow (indication of flat)      |
//+------------------------------------------------------------------+
int IsRange()
  {
//--- get the ATR value on the last completed bar
   double atr_buffer[];
   if(CopyBuffer(ExtATRHandle, 0, 1, 1, atr_buffer)==-1)
     {
      PrintFormat("%s: Failed CopyBuffer(ExtATRHandle,0,1,2,atr_buffer), code=%d", __FILE__, GetLastError());
      return(NO_VALUE);
     }
   double atr=atr_buffer[0];
//--- get the channel borders
   if(!ChannelBoundsCalculate(ExtUpChannel, ExtLowChannel))
      return(NO_VALUE);
   ExtChannelRange=ExtUpChannel-ExtLowChannel;
//--- compare the channel width with the ATR value
   if(ExtChannelRange<InpATRCoeff*atr)
      return(true);
//--- range not detected
   return(false);
  }
//+------------------------------------------------------------------+
//| Gets the values of the channel borders                           |
//+------------------------------------------------------------------+
bool ChannelBoundsCalculate(double &up, double &low)
  {
//--- get the Bollinger Bands width
   double bbup_buffer[];
   double bblow_buffer[];
   if(CopyBuffer(ExtBBHandle, 1, 1, 1, bbup_buffer)==-1)
     {
      PrintFormat("%s: Failed CopyBuffer(ExtBBHandle,0,1,2,bbup_buffer), code=%d", __FILE__, GetLastError());
      return(false);
     }

   if((CopyBuffer(ExtBBHandle, 2, 1, 1, bblow_buffer)==-1))
     {
      PrintFormat("%s: Failed CopyBuffer(ExtBBHandle,0,1,2,bblow_buffer), code=%d", __FILE__, GetLastError());
      return(false);
     }
   low=bblow_buffer[0];
   up =bbup_buffer[0];
//--- done
   return(true);
  }
//+------------------------------------------------------------------+
//| Returns true if there are open positions                         |
//+------------------------------------------------------------------+
bool PositionExist()
  {
//--- an indication of the presence of an open position
   bool exist=false;
//--- go through the list of all positions
   int positions=PositionsTotal();
   for(int i=0; i<positions; i++)
     {
      if(PositionGetTicket(i)!=0)
        {
         //--- get the name of the symbol and the position id (magic)
         string symbol=PositionGetString(POSITION_SYMBOL);
         long   magic =PositionGetInteger(POSITION_MAGIC);
         //--- if they correspond to our values
         if(symbol==Symbol() && magic==InpMagicNumber)
           {
            //--- yes, this is the right position, stop the search
            exist=true;
            break;
           }
        }
     }
//--- return the open position search result
   return(exist);
  }
//+------------------------------------------------------------------+
//| Returns true if there are pending limit orders                   |
//+------------------------------------------------------------------+
bool OrderExist()
  {
//--- go through the list of all orders
   int orders=OrdersTotal();
   for(int i=0; i<orders; i++)
     {
      if(OrderGetTicket(i)!=0)
        {
         //--- get the name of the symbol and the order id (magic)
         string symbol=OrderGetString(ORDER_SYMBOL);
         long   magic =OrderGetInteger(ORDER_MAGIC);
         //--- if they correspond to our values
         if(symbol==Symbol() && magic==InpMagicNumber)
           {
            //--- yes, this is the right order, stop the search
            return(true);
           }
        }
     }
//--- return the limit order search result
   return(false);
  }
//+------------------------------------------------------------------+
//| Deletes limit orders                                             |
//+------------------------------------------------------------------+
bool DeleteLimitOrders(void)
  {
//--- go through the list of all orders
   int orders=OrdersTotal();
   for(int i=0; i<orders; i++)
     {
      if(!ExtOrderInfo.SelectByIndex(i))
        {
         PrintFormat("OrderSelect() failed: Error=", GetLastError());
         return(false);
        }
      //--- get the name of the symbol and the position id (magic)
      string symbol=ExtOrderInfo.Symbol();
      long   magic =ExtOrderInfo.Magic();
      ulong  ticket=ExtOrderInfo.Ticket();
      //--- if they correspond to our values
      if(symbol==Symbol() && magic==InpMagicNumber)
        {
         if(ExtTrade.OrderDelete(ticket))
            Print(ExtTrade.ResultRetcodeDescription());
         else
            Print("OrderDelete() failed! ", ExtTrade.ResultRetcodeDescription());
         return(false);
        }
     }
//---
   return(true);
  }
//+------------------------------------------------------------------+
//| Send a limit orders according to trend                           |
//+------------------------------------------------------------------+
bool SendLimitOrder(int trend)
  {
   double price;
   double stoploss;
   double takeprofit;
   ExtSymbolInfo.Refresh();
   ExtSymbolInfo.RefreshRates();
   int digits=ExtSymbolInfo.Digits();
   double spread=ExtSymbolInfo.Ask()-ExtSymbolInfo.Bid();
//--- uptrend
   if(trend==1)
     {
      price=NormalizeDouble(ExtLowChannel, digits);
      //--- open price of Buy Limit order must be lower than current Ask
      if(price>ExtSymbolInfo.Ask())
         return(true);
      stoploss  =NormalizeDouble(price-ExtChannelRange, digits);
      takeprofit=NormalizeDouble(price+ExtChannelRange, digits);
      if(!ExtTrade.BuyLimit(InpLot, price, Symbol(), stoploss, takeprofit))
        {
         PrintFormat("%s BuyLimit at %G (sl=%G tp=%G) failed. Ask=%G error=%d",
                     Symbol(), price, stoploss, takeprofit, ExtSymbolInfo.Ask(), GetLastError());
         return(false);
        }
     }
//--- downtrend
   if(trend==-1)
     {
      price=NormalizeDouble(ExtUpChannel+spread, digits);
      //--- open price of Sell Limit order must be higher than current Bid
      if(price<ExtSymbolInfo.Bid())
         return(true);
      stoploss  =NormalizeDouble(price+ExtChannelRange, digits);
      takeprofit=NormalizeDouble(price-ExtChannelRange, digits);
      if(!ExtTrade.SellLimit(InpLot, price, Symbol(), stoploss, takeprofit))
        {
         PrintFormat("%s SellLimit at %G (sl=%G tp=%G) failed. Bid=%G error=%d",
                     Symbol(), price, stoploss, takeprofit, ExtSymbolInfo.Bid(), GetLastError());
         return(false);
        }
     }
//---
   return(true);
  }
//+------------------------------------------------------------------+
//| Move limit orders according to trend                             |
//+------------------------------------------------------------------+
bool ModifyLimitOrder(int trend)
  {
   double price;
   double stoploss;
   double takeprofit;
   ulong  ticket;
   ExtSymbolInfo.Refresh();
   ExtSymbolInfo.RefreshRates();
   int digits=ExtSymbolInfo.Digits();
   double point=ExtSymbolInfo.Point();
   double spread=ExtSymbolInfo.Ask()-ExtSymbolInfo.Bid();
//--- uptrend
   if(trend==1)
     {
      price=NormalizeDouble(ExtLowChannel, digits);
      //--- open price of Buy Limit order must be lower than current Ask
      if(price>ExtSymbolInfo.Ask())
         return(true);
      stoploss  =NormalizeDouble(price-ExtChannelRange, digits);
      takeprofit=NormalizeDouble(price+ExtChannelRange, digits);
      //--- go through the list of all orders
      int orders=OrdersTotal();
      for(int i=0; i<orders; i++)
        {
         if((ticket=OrderGetTicket(i))!=0)
           {
            //--- get the name of the symbol and the order id (magic)
            string symbol=OrderGetString(ORDER_SYMBOL);
            long   magic =OrderGetInteger(ORDER_MAGIC);
            ENUM_ORDER_TYPE type=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
            //--- if they correspond to our values
            if(type==ORDER_TYPE_BUY_LIMIT && symbol==Symbol() && magic==InpMagicNumber)
              {
               //--- if the new price does not differ from the current open price
               double current_price=OrderGetDouble(ORDER_PRICE_OPEN);
               if(MathAbs(current_price-price)<=point)
                  continue; // skip the order
               //--- modify an order
               if(!ExtTrade.OrderModify(ticket, price, stoploss, takeprofit, 0, 0))
                 {
                  PrintFormat("%s Failed Modify BuyLimit at %G (sl=%G tp=%G)failed. Error=%d",
                              Symbol(), price, stoploss, takeprofit, GetLastError());
                  return(false);
                 }
              }
           }
        }
     }
//--- downtrend
   if(trend==-1)
     {
      price=NormalizeDouble(ExtUpChannel+spread, digits);
      //--- open price of Sell Limit order must be higher than current Ask
      if(price<ExtSymbolInfo.Bid())
         return(true);
      stoploss  =NormalizeDouble(price+ExtChannelRange, digits);
      takeprofit=NormalizeDouble(price-ExtChannelRange, digits);
      //--- go through the list of all orders
      int orders=OrdersTotal();
      for(int i=0; i<orders; i++)
        {
         if((ticket=OrderGetTicket(i))!=0)
           {
            //--- get the name of the symbol and the order id (magic)
            string symbol=OrderGetString(ORDER_SYMBOL);
            long   magic =OrderGetInteger(ORDER_MAGIC);
            ENUM_ORDER_TYPE type=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
            //--- if they correspond to our values
            if(type==ORDER_TYPE_SELL_LIMIT && symbol==Symbol() && magic==InpMagicNumber)
              {
               //--- if the new price does not differ from the current open price
               double current_price=OrderGetDouble(ORDER_PRICE_OPEN);
               if(MathAbs(current_price-price)<=point)
                  continue; // skip the order
               //--- modify an order
               if(!ExtTrade.OrderModify(ticket, price, stoploss, takeprofit, 0, 0))
                 {
                  PrintFormat("%s Failed Modify SellLimit at %G (sl=%G tp=%G)failed. Error=%d",
                              Symbol(), price, stoploss, takeprofit, GetLastError());
                  return(false);
                 }
              }
           }
        }
     }
//---
   return(true);
  }
//+------------------------------------------------------------------+
