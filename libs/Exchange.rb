require 'thread'
require 'csv'
require 'statsample'


# This class is the parent class for all exchange classes. 
# To support a particular exchange, one needs to derive from this class and implement the following
# methods (see ExchangeSimulation for an example):
# * get_balance
# * place_market_order(type, volume, fee_in_base_currency)
# * place_limit_order(type, volume, limit, fee_in_base_currency)
# * cancel_order(order_id)
# * get_order_status(order_id)
class Exchange
  attr_accessor :initial_balance_base_currency, :initial_balance_quote_currency
  
  # Initialize exchange (usually called by a child class).
  #
  # *Params:*
  # +timer+::           Timer instance
  # +base_currency+::   base currency string (e.g. "+XBT+")
  # +quote_currency+::  quote currency string (e.g. "+USD+")
  def initialize(timer, base_currency, quote_currency)
    @timer = timer
    
    @pair_name = "#{base_currency}#{quote_currency}"
    @pair_method = "X#{base_currency}Z#{quote_currency}"
    
    @quote_currency = "Z#{quote_currency}"
    @base_currency = "X#{base_currency}"
    
    @database_mutex = Mutex.new
    @TimePoint = Struct.new("TimePoint", :time, :value)
    @bids = Array.new
    @asks = Array.new
    
    @OrderStatus = Struct.new(:status, :vol, :vol_exec, :fee, :price, :type)
  end

  # Starts the exchange. Use this method to start collecting price data.
  def start    
  end
  
  # Shuts down the exchange.
  def stop
  end

  # Resets the internal state of the exchange instance. This method is only required if the exchange is used for backtesting.
  def reset
  end
  
  # Returns the current buy price for the requested volume.
  #
  # *Params:*
  # +vol+:: volume in base currency
  #
  # *Returns:*
  # +price+:: buy price in base currency
  def get_buy_price(vol)
    current_asks = nil
    @database_mutex.synchronize do
      raise StandardError, "database is empty" if @asks.empty?
      
      current_time = @timer.get_time
      idx = @asks.bsearch_index {|data_point| data_point.time >= current_time}
      idx = idx.nil? ? @asks.size - 1 : idx
      
      current_asks = @asks[idx].value
    end
    # let's assume db_price is ascending
    
    get_buy_price_priv(vol, current_asks)
  end
  
  # Returns the current sell price for the requested volume.
  #
  # *Params:*
  # +vol+:: volume in base currency
  #
  # *Returns:*
  # +price+:: sell price in base currency
  def get_sell_price(vol)
    current_bids = nil
    @database_mutex.synchronize do
      raise StandardError, "database is empty" if @bids.empty?
      
      current_time = @timer.get_time
      idx = @bids.bsearch_index {|data_point| data_point.time >= current_time}
      idx = idx.nil? ? @bids.size - 1 : idx
      
      current_bids = @bids[idx].value
    end
    # let's assume db_price is ascending
    
    get_sell_price_priv(vol, current_bids)
  end
  
  # Returns the history of sell prices for the requested volume in a given time interval.
  #
  # *Params:*
  # +vol+::         volume
  # +start_time+::  start of time interval given as number of seconds since the Epoch
  # +end_time+::    end of time interval given as number of seconds since the Epoch
  #
  # *Returns:*
  # +prices+:: array of sell prices in base currency
  def get_sell_price_history(vol, start_time, end_time)
    bids_data_points = nil
    @database_mutex.synchronize do
      raise StandardError, "database is empty" if @bids.empty?
      start_idx = @bids.bsearch_index {|data_point| data_point.time >= start_time}
      end_idx = @bids.bsearch_index {|data_point| data_point.time >= end_time}
      start_idx = start_idx.nil? ? @bids.size - 1 : start_idx
      end_idx = end_idx.nil? ? @bids.size - 1 : end_idx
      
      bids_data_points = @bids[start_idx..end_idx]
    end
    
    prices = Array.new
    times = Array.new
    for bids_data_point in bids_data_points
      current_bids = bids_data_point.value      
      sell_price = get_sell_price_priv(vol, current_bids)
      
      prices << sell_price
      times << bids_data_point.time
    end
    sell_data = Daru::DataFrame.new({:time => times, :price => prices}, {:order => [:time, :price]})
    
    # subtract time offset
    sell_data[:time] -= sell_data[:time][0]
    
    return sell_data
  end
  
  # Returns the history of buy prices for the requested volume in a given time interval.
  #
  # *Params:*
  # +vol+::         volume
  # +start_time+::  start of time interval given as number of seconds since the Epoch
  # +end_time+::    end of time interval given as number of seconds since the Epoch
  #
  # *Returns:*
  # +prices+:: array of buy prices in base currency
  def get_buy_price_history(vol, start_time, end_time)
    asks_data_points = nil
    @database_mutex.synchronize do
      raise StandardError, "database is empty" if @asks.empty?
      start_idx = @asks.bsearch_index {|data_point| data_point.time >= start_time}
      end_idx = @asks.bsearch_index {|data_point| data_point.time >= end_time}
      start_idx = start_idx.nil? ? @asks.size - 1 : start_idx
      end_idx = end_idx.nil? ? @asks.size - 1 : end_idx

      asks_data_points = @asks[start_idx..end_idx]
    end
    
    prices = Array.new
    times = Array.new
    for asks_data_point in asks_data_points
      current_asks = asks_data_point.value      
      buy_price = get_buy_price_priv(vol, current_asks)
      
      prices << buy_price
      times << asks_data_point.time
    end    
    buy_data = Daru::DataFrame.new({:time => times, :price => prices}, {:order => [:time, :price]})

    # subtract time offset
    buy_data[:time] -= buy_data[:time][0]
    
    return buy_data
  end
  
  # Returns the median of the buy price for the requested volume in a given time interval.
  #
  # *Params:*
  # +vol+::         volume in base currency
  # +start_time+::  start of time interval given as number of seconds since the Epoch
  # +end_time+::    end of time interval given as number of seconds since the Epoch
  #
  # *Returns:*
  # +price+:: median buy price in base currency
  def get_avg_buy_price(vol, start_time, end_time)
    data = get_buy_price_history(vol, start_time, end_time)
    return data[:price].median
  end
  
  # Returns the median of the sell price for the requested volume in a given time interval.
  #
  # *Params:*
  # +vol+::         volume in base currency
  # +start_time+::  start of time interval given as number of seconds since the Epoch
  # +end_time+::    end of time interval given as number of seconds since the Epoch
  #
  # *Returns:*
  # +price+:: median sell price in base currency
  def get_avg_sell_price(vol, start_time, end_time)
    data = get_sell_price_history(vol, start_time, end_time)
    return data[:price].median
  end
  
  # Returns the slope of the buy price for the requested volume in a given time interval.
  #
  # *Params:*
  # +vol+::         volume in base currency
  # +start_time+::  start of time interval given as number of seconds since the Epoch
  # +end_time+::    end of time interval given as number of seconds since the Epoch
  #
  # *Returns:*
  # +price+:: slope of the buy price
  def get_slope_buy_price(vol, start_time, end_time)
    data = get_buy_price_history(vol, start_time, end_time)
    
    reg = Statsample::Regression::Simple.new_from_vectors(data[:time], data[:price])
    return reg.b
  end
  
  # Returns the slope of the sell price for the requested volume in a given time interval.
  #
  # *Params:*
  # +vol+::         volume in base currency
  # +start_time+::  start of time interval given as number of seconds since the Epoch
  # +end_time+::    end of time interval given as number of seconds since the Epoch
  #
  # *Returns:*
  # +price+:: slope of the sell price
  def get_slope_sell_price(vol, start_time, end_time)
    data = get_sell_price_history(vol, start_time, end_time)
    
    reg = Statsample::Regression::Simple.new_from_vectors(data[:time], data[:price])
    return reg.b
  end
  
  private
  
  # Returns the weighted buy price for the requested volume given the asks from an order book
  #
  # *Params:*
  # +vol+::   volume
  # +asks+::  array of asks from the order book, each ask is again a 2-element array where index 0 is the price and index 1 is the volume
  #
  # *Returns:*
  # +price+:: buy price in base currency
  def get_buy_price_priv(vol, asks)
    rest_vol = vol
    weighted_price = 0.0
    for ask in asks
      db_price = ask[0].to_f
      db_vol = ask[1].to_f
      if rest_vol > db_vol
        weighted_price += db_vol * db_price
        rest_vol -= db_vol
      else
        weighted_price += rest_vol * db_price
        rest_vol = 0.0
        break
      end
    end
    
    raise StandardError, "not enough volume available on market" if rest_vol > 0
    
    return weighted_price / vol
  end
  
  # Returns the weighted sell price for the requested volume given the bids from an order book
  #
  # *Params:*
  # +vol+::   volume
  # +bids+::  array of bids from the order book, each bid is again a 2-element array where index 0 is the price and index 1 is the volume
  #
  # *Returns:*
  # +price+:: sell price in base currency
  def get_sell_price_priv(vol, bids)
    rest_vol = vol
    weighted_price = 0.0
    for bid in bids
      db_price = bid[0].to_f
      db_vol = bid[1].to_f
      if rest_vol > db_vol
        weighted_price += db_vol * db_price
        rest_vol -= db_vol
      else
        weighted_price += rest_vol * db_price
        rest_vol = 0.0
        break
      end
    end
    
    raise StandardError, "not enough volume available on market" if rest_vol > 0
    
    return weighted_price / vol
  end
end