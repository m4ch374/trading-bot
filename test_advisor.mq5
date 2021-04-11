//+------------------------------------------------------------------+
//|                                                 test_advisor.mq5 |
//|                        Copyright 2021, MetaQuotes Software Corp. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2021, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "1.00"

//--- libraries
#include <Trade\Trade.mqh>
#include <Math\Stat\Stat.mqh>

//--- enums

//--- MA methods
enum Enum_Ma_Method {
   SMA = MODE_SMA,
   EMA = MODE_EMA,
   SMMA = MODE_SMMA,
   LWMA = MODE_LWMA
};

//--- trade methods
enum Trade_Method {
   Fixed,
   ATR
};

//--- position sizing method
enum Position_Sizing_Method {
   Fixed_Volume,
   Variable_Volume
};

//--- custom metric selection
enum Custom_Performance_Metric {
   Modified_Profit_Factor,
   No_Custom_Metric
};

//--- structs
struct PendingTradeInfo {
   // Pending trade data
   ulong openTradeOrderTicket;
   double pendingTradeLoss;
   double pendingTradeProfit;
   char pendingTradeDirection;
   
   // Pending trade extra properties
   // Used when there is error
   bool isPendingClose;
   bool isPendingOpen;
   bool isSlip;
};

//--- input parameters
input string header_line; // ============ Indicator parameters =========
input int ma_period = 20; // MA period
input int ma_shift = 0; // MA shift
input Enum_Ma_Method ma_method = SMA; // MA method

input string dashed_line; // ==================== EA Symbols =====================
input string symbol_to_process = "EURUSD_dukascopy"; // Enter Symbol(s) to test or ALL or CURRENT

input string dashed_line_1; // ===================== Money Management==========================
input Position_Sizing_Method sizing_method = Fixed_Volume; // Position sizing method
input double pos_volume = 0.01; // Position Volume in Lots (Percent to risk if variable)
input Trade_Method trade_methods = Fixed; // Trade method: ATR or Fixed
input double sl_value; // ATR Stop Loss Multiplier if ATR, fixed pips if Fixed
input double tp_value; // ATR Take Profit Multiplier if ATR, fixed pips if Fixed

input string dashed_line_2; // ============= Custom Performance Metric Selection =========
input Custom_Performance_Metric metric = Modified_Profit_Factor; // Select custom metric to use
input double trade_exclusion_multiple = 4; //Exclude extreme trades based on the multiple of sd

//--- Global varables and handlers
CTrade trades; //--- Trade instance
int handler_ma[]; //--- Handler for MA
int handler_atr[]; //--- Handler for ATR

//--- symbol inputs
string all_symbol_string = "EURUSD_dukascopy|EURJPY_dukascopy";
int symbol_count;
string symbol_array[];

// Global variable for pending trade info
PendingTradeInfo pending_trade[];

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {

   Print("EA will start now");
   
   // setup symbol data
   symbol_count = get_symbol_count(symbol_to_process);
   
   // setup pending trade info data
   ArrayResize(pending_trade, symbol_count);
   setup_pending_trade();

   // setup indicator data
   
   // setup MA data
   ArrayResize(handler_ma, symbol_count);
   if(!setup_ma_handler()) {
      return(INIT_FAILED);
   }
   
   // setup ATR data if trade mode is ATR
   if (trade_methods == ATR) {
      ArrayResize(handler_atr, symbol_count);
      if (!setup_atr_handler()) {
         return(INIT_FAILED);
      }
   }
   
   return(INIT_SUCCEEDED);
}


//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   //--- MA deinit
   for (int i = 0; i < symbol_count; i++) {
      IndicatorRelease(handler_ma[i]);
   }
   
   //--- ATR deinit
   if (trade_methods == ATR) {
      for (int i = 0; i < symbol_count; i++) {
         IndicatorRelease(handler_atr[i]);
      }
   }
   
   Print("EA stopped");
}


//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
//---
   // loop through all instuments for each new tick
   for (int i = 0; i < symbol_count; i++) {
      // If there is on going trade, check if it hits tp or sl
      track_trade(i);
   
      // Process if a new bar is detected
      if (is_new_bar()) {
         
         // open trade if there is trade not yet opened due to market close
         if (pending_trade[i].isPendingOpen) {
            process_trade_open(pending_trade[i].pendingTradeDirection, i);
         }
      
         // get entry and exit status
         char ma_entry_status = get_ma_entry_status(i);
         char ma_exit_status = get_ma_exit_status(i);
         
         // conditions
         bool trade_entry_condition_satisfied = (ma_entry_status == 'L' || ma_entry_status == 'S') && pending_trade[i].openTradeOrderTicket == 0;
         bool trade_exit_condition_satisfied = (ma_exit_status == 'L' || ma_exit_status == 'S') && pending_trade[i].openTradeOrderTicket != 0;
         
         if (trade_entry_condition_satisfied && !pending_trade[i].isSlip) {
            process_trade_open(ma_entry_status, i);
         }
         
         if (trade_exit_condition_satisfied || pending_trade[i].isPendingClose) {
            process_trade_close(i);
         }
      }
      
      // If requote error is returned due to slippage (unable to enter market at price)
      // Try enter in next tick
      if (pending_trade[i].isSlip) {
         process_trade_open(pending_trade[i].pendingTradeDirection, i);
      }
   }
}

//+------------------------------------------------------------------+
//| Expert tester function                                           |
//+------------------------------------------------------------------+
double OnTester() {
   double custom_metric = 0;
   
   if (metric == Modified_Profit_Factor) {
      custom_metric = get_modified_profit_factor();
   }
   else {
      custom_metric = 0;
   }
   
   return custom_metric;
}

//+------------------------------------------------------------------+

//-- funtions

// returns the number of symbol that the EA will process
int get_symbol_count(string inputs) {
   int count = 0;
   string target_string = "";
   
   if (inputs == "CURRENT") {
      count = 1;

      ArrayResize(symbol_array, 1);
      symbol_array[0] = _Symbol;

      Print("EA will process" + symbol_array[0]);
   }
   else {
      if (inputs == "ALL"){
         target_string = all_symbol_string;
      }
      else {
         target_string = inputs;
      }
      count = StringSplit(target_string, '|', symbol_array);
   }
   
   return count;
}

// sets up pending trade info
void setup_pending_trade() {
   for (int i = 0; i < symbol_count; i++) {
      pending_trade[i].openTradeOrderTicket = 0;
      pending_trade[i].pendingTradeLoss = NULL;
      pending_trade[i].pendingTradeProfit = NULL;
      pending_trade[i].pendingTradeDirection = 0;
      pending_trade[i].isPendingClose = false;
      pending_trade[i].isPendingOpen = false;
      pending_trade[i].isSlip = false;
   }
}

// sets up the handler for MA
bool setup_ma_handler() {
   for (int i = 0; i < symbol_count; i++) {
      ResetLastError();

      handler_ma[i] = iMA(symbol_array[i], _Period, ma_period, ma_shift, ENUM_MA_METHOD(ma_method), PRICE_CLOSE);
      
      if (handler_ma[i] == INVALID_HANDLE) {
         Print(GetLastError());
         MessageBox("Failed to create handle for" + symbol_array[i]);
         return(false);
      }

      Print("Handle for MA " + symbol_array[i] + " created successfully");
   }
   
   return(true);
}

// sets up handler for ATR
bool setup_atr_handler() {
   for (int i = 0; i < symbol_count; i++) {
      ResetLastError();

      handler_atr[i] = iATR(symbol_array[i], _Period, 14);
      
      if (handler_atr[i] == INVALID_HANDLE) {
         Print(GetLastError());
         MessageBox("Failed to create handle for" + symbol_array[i]);
         return(false);
      }

      Print("Handle for ATR " + symbol_array[i] + " created successfully");
   }
   
   return(true);
}

// check if trade hits tp or sl if there is on going trade
void track_trade(int i) {

   // process if there is on going trade
   if (pending_trade[i].openTradeOrderTicket != 0) {
            
      // If trade is long and hits tp or sl
      if (pending_trade[i].pendingTradeDirection == 'L') {
         double candle_close = iClose(symbol_array[i], _Period, 0);
         if (candle_close >= pending_trade[i].pendingTradeProfit || candle_close <= pending_trade[i].pendingTradeLoss) {
            reset_pending_trade_info(i);
         }
      }
      
      // If trade is short and hits tp or sl
      if (pending_trade[i].pendingTradeDirection == 'S') {
         double candle_close = iClose(symbol_array[i], _Period, 0);
         if (candle_close <= pending_trade[i].pendingTradeProfit || candle_close >= pending_trade[i].pendingTradeLoss) {
            reset_pending_trade_info(i);
         }
      }
   }
}

// determine if the new tick is a new bar
bool is_new_bar() {
   static datetime time;
   datetime current_time = iTime(_Symbol,_Period,0);
   
   if(time != current_time) {
      time = current_time;
      return(true);
   }
   else {
      return(false);
   }
}

// gets the entry signal produced by MA
char get_ma_entry_status(int i) {

   // gets ma value
   double ma_value_buffer[];
   bool ma_buffer_success = copy_indi_array_values(handler_ma[i],0,1,3,ma_value_buffer);
   
   // get candle rates
   MqlRates candle[];
   bool candle_buffer_success = get_candle_rates(symbol_array[i], _Period, 1, 3, candle);
   
   bool no_buffer_errors = ma_buffer_success && candle_buffer_success;
   
   if (candle[0].close > ma_value_buffer[0] && candle[1].close < ma_value_buffer[1] && no_buffer_errors) {
      return('L');
   }
   else if (candle[0].close < ma_value_buffer[0] && candle[1].close > ma_value_buffer[1] && no_buffer_errors) {
      return('S');
   }
   else {
      return('N');
   }
}

// gets the exit signal produced by MA
char get_ma_exit_status(int i) {
   // gets ma value
   double ma_value_buffer[];
   bool ma_buffer_success = copy_indi_array_values(handler_ma[i],0,1,3,ma_value_buffer);
   
   // get candle rates
   MqlRates candle[];
   bool candle_buffer_success = get_candle_rates(symbol_array[i], _Period, 1, 3, candle);
   
   bool no_buffer_errors = ma_buffer_success && candle_buffer_success;
   
   if (candle[0].close > ma_value_buffer[0] && candle[1].close < ma_value_buffer[1] && no_buffer_errors) {
      return('S');
   }
   else if (candle[0].close < ma_value_buffer[0] && candle[1].close > ma_value_buffer[1] && no_buffer_errors) {
      return('L');
   }
   else {
      return('N');
   }
}

// process opening of the trade
void process_trade_open(char trade_direction, int i) {

   bool successful_order = false;
   double close = iClose(symbol_array[i], _Period, 0);
   
   // get relative stop loss and profit
   // ie pips away from close
   double stop_loss = get_stop_loss(i);
   double take_profit = get_take_profit(i);
   
   // initialize sl and tp
   double trade_sl = NULL;
   double trade_tp = NULL;
   
   // gets the lots to trade
   double lots = get_lots(stop_loss, i);
   
   if (trade_direction == 'L') {
      // set sl and tp values
      trade_sl = close - stop_loss;
      trade_tp = close + take_profit;
      
      // place buy position
      successful_order = trades.Buy(lots, symbol_array[i], 0, trade_sl, trade_tp);
   }
   
   if (trade_direction == 'S') {
      // set sl and tp values
      trade_sl = close + stop_loss;
      trade_tp = close - take_profit;
      
      // place sell position
      successful_order = trades.Sell(lots, symbol_array[i], 0, trade_sl, trade_tp);
   }
   
   if (successful_order) {
   
      // Set trading info
      Print("Order successful");
      pending_trade[i].openTradeOrderTicket = trades.ResultOrder();
      pending_trade[i].pendingTradeLoss = trade_sl;
      pending_trade[i].pendingTradeProfit = trade_tp;
      pending_trade[i].pendingTradeDirection = trade_direction;
      
      // reset pending trade properties
      pending_trade[i].isPendingOpen = false;
      pending_trade[i].isSlip = false;
   }
   else {
      // Gets the result code
      uint result_code = trades.ResultRetcode();
      
      // Error generated when market is closed
      // set pending open to true
      if (result_code == 10018) {
         pending_trade[i].isPendingOpen = true;
         pending_trade[i].pendingTradeDirection = trade_direction;
      }
      
      // Error generated when there is requotes (slippage)
      // set slipping to true
      if (result_code == 10004) {
         pending_trade[i].isSlip = true;
         pending_trade[i].pendingTradeDirection = trade_direction;
      }
      
      Print("Order unsuccessful: ", result_code);
   }
}

// process the close of a trade
void process_trade_close(int i) {
   if (trades.PositionClose(pending_trade[i].openTradeOrderTicket, 3)) {
      Print("Exit Successful");
      reset_pending_trade_info(i);
   }
   else {
      // Gets the result code
      uint result_code = trades.ResultRetcode();
   
      // if unable to close position due to market close
      if (result_code == 10018) {
         pending_trade[i].isPendingClose = true;
      }
      
      Print("Exit unsuccessful: ", result_code);
   }
}

// Modified profit factor that normalizes position size
// And excludes extreme trades
double get_modified_profit_factor() {

   // set up required variables
   HistorySelect(0,TimeCurrent());
   int number_of_deals = HistoryDealsTotal();
   
   // loop through deals in datetime order
   int number_of_positions = 0;
   double position_net_profit[];
   double position_volume[];
   
   double deal_entry_commission = 0;
   for (int i = 0; i < number_of_deals; i++) {
      ulong deal_ticket = HistoryDealGetTicket(i);
      
      // get the commission of entry trade
      if (HistoryDealGetInteger(deal_ticket,DEAL_ENTRY) == DEAL_ENTRY_IN) {
         deal_entry_commission = HistoryDealGetDouble(deal_ticket,DEAL_COMMISSION);
      }
      
      // set profit and volumes in array if the deal is a closing deal
      if (HistoryDealGetInteger(deal_ticket, DEAL_ENTRY) == DEAL_ENTRY_OUT) {
      
         // resize arrays based on number of closed position
         number_of_positions++;
         ArrayResize(position_net_profit,number_of_positions);
         ArrayResize(position_volume, number_of_positions);
         
         position_net_profit[number_of_positions - 1] = HistoryDealGetDouble(deal_ticket,DEAL_PROFIT) + deal_entry_commission + HistoryDealGetDouble(deal_ticket,DEAL_SWAP) + HistoryDealGetDouble(deal_ticket,DEAL_COMMISSION);
         position_volume[number_of_positions - 1] = HistoryDealGetDouble(deal_ticket,DEAL_VOLUME);
      }
   }
   
   // calculate modified profit factor
   double sum_of_profit = 0;
   double sum_of_loss = 0;
   double net_profit_mean = MathMean(position_net_profit);
   double net_profit_sd = MathStandardDeviation(position_net_profit);
   
   for (int i = 0; i < number_of_positions; i++) {
      // if net profit is within bounds: `mean + mul*sd` and `mean - mul*sd`
      if (position_net_profit[i] < net_profit_mean + (trade_exclusion_multiple*net_profit_sd) || position_net_profit[i] > net_profit_mean - (trade_exclusion_multiple*net_profit_sd)) {
         position_net_profit[i] /= position_volume[i];
         
         if (position_net_profit[i] > 0) {
            sum_of_profit += position_net_profit[i];
         }
         else {
            sum_of_loss += position_net_profit[i];
         }
      }
   }
   
   // Ensure loss is not equals to 0 to prevent error in calculations
   if (sum_of_loss != 0) {
      return MathAbs(sum_of_profit / sum_of_loss);
   } else {
      return sum_of_profit;
   }
}

//--- sub funtions

// get the MQLrates and check if it successfully return it
bool get_candle_rates(string symbol_name, ENUM_TIMEFRAMES timeframe, int start_pos, int count, MqlRates &rates[]) {
   // setup candle values
   if (CopyRates(symbol_name, timeframe, start_pos, count, rates) != count) {
      Print("Copy candle rates failed");
      return(false);
   }
   else {
      ArraySetAsSeries(rates,true);
      return(true);
   }
}

// get the specific indicator value and check if it successfully return it
bool copy_indi_array_values(int indi_handle, int buffer_num, int start_pos, int count, double &local_buffer[]) {
   if(CopyBuffer(indi_handle, buffer_num, start_pos, count, local_buffer) != count) {
      Print("Copy buffer failed");
      return(false);
   }
   else {
      ArraySetAsSeries(local_buffer,true);
      return(true);
   }
}

// get the stop loss of the trade
double get_stop_loss(int i) {
   if(trade_methods == ATR) {
      double atr_buffer_value[];
      copy_indi_array_values(handler_atr[i], 0, 0, 3, atr_buffer_value);
      
      return atr_buffer_value[1] * sl_value;
   } 
   else {
      return ((sl_value * 10)/MathPow(10, _Digits));
   }
}

// get the profit of the trade
double get_take_profit(int i) {
   if(trade_methods == ATR) {
      double atr_buffer_value[];
      copy_indi_array_values(handler_atr[i], 0, 0, 3, atr_buffer_value);
      
      return atr_buffer_value[1] * tp_value;
   } 
   else {
      return ((tp_value * 10)/MathPow(10, _Digits));
   }
}

double get_lots(double stop_loss, int i) {
   double lots = 0;
   if (sizing_method == Variable_Volume) {
      double amount_at_risk = AccountInfoDouble(ACCOUNT_BALANCE) * (pos_volume/100);
      double risk_per_pip = amount_at_risk / (stop_loss * MathPow(10, _Digits)); // convert stop loss from price to points
      double pip_value = SymbolInfoDouble(symbol_array[i], SYMBOL_TRADE_TICK_VALUE);
      lots = NormalizeDouble(risk_per_pip / pip_value, 2);
   } else {
      lots = pos_volume;
   }
   
   return lots;
}

// reset some of the values of the pending trade info
void reset_pending_trade_info(int i) {
   pending_trade[i].openTradeOrderTicket = 0;
   pending_trade[i].isPendingClose = false;
   pending_trade[i].pendingTradeDirection = 0;
   pending_trade[i].pendingTradeLoss = NULL;
   pending_trade[i].pendingTradeProfit = NULL;
}

//TODO: implement custom performance metric
// 1. Normalized PF (finished)
// 2. CAGR/mean DD
// 3. R2
// 4. custom ranking system