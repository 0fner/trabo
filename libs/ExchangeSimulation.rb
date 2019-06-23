require 'Exchange'
require 'thread'
require 'csv'
require 'nyaplot'

# This class simulates an exchange. Use it for backtesting. 
class ExchangeSimulation < Exchange
  attr_accessor :initial_balance_base_currency, :initial_balance_quote_currency  

  # Initializes the exchange.
  #
  # *Params:*
  # +timer+::           Timer instance
  # +base_currency+::   base currency string (e.g. "+XBT+")
  # +quote_currency+::  quote currency string (e.g. "+USD+")
  # +asks_data_file+::  path to CSV file containing ask data (e.g. "+data/asks.csv+")
  # +bids_data_file+::  path to CSV file containg bid data (e.g. "+data/bids.csv+")
  def initialize(timer, base_currency, quote_currency, asks_data_file, bids_data_file)
    super(timer, base_currency, quote_currency)
        
    @run = true
    @run_mutex = Mutex.new
    
    @last_order_id = 0
    @order_id_mutex = Mutex.new
    
    # order is executed between 0 and @max_order_execution_time seconds after order is placed
    @max_order_execution_time = 30 # [s]
    
    # the @Order struct represents every information associated with an order
    @Order = Struct.new(:order_id, :type, :creation_time, :execution_time, :fee_rate, :fee, :fee_in_base_currency, :volume, :price, :canceled)
    @orders = Array.new
    @orders_mutex = Mutex.new
    
    # fees charged by the exchange
    @fees_taker = 0.0026
    @fees_maker = 0.0016
    
    @BalancePosition = Struct.new(:time, :base_currency, :quote_currency)
    @balance = Array.new
    @balance_mutex = Mutex.new
    
    asks_cache_file = asks_data_file + ".cache"
    bids_cache_file = bids_data_file + ".cache"
    
    # check if cache file exits, otherwise load .csv file
    if File.exist?(asks_cache_file)
      $logger.info("loading asks data from cache file...")
      ser_asks = IO.binread(asks_cache_file)
      @asks = Marshal.load(ser_asks)
    else
      $logger.info("loading asks data from CSV file...")
      IO.foreach(asks_data_file) do |line|
        data = line.split(",").map {|item| item.to_f}      
        csv_timestamp = data[3]
        csv_ask = data[0..2]

        ask = @asks.bsearch {|time_point| time_point.time >= csv_timestamp}
        if ask.nil?
          @asks << @TimePoint.new(csv_timestamp, Array.new << csv_ask)
        else
          ask.value << csv_ask
        end
      end
      
      # serialize array into cache file
      $logger.info("serializing asks data to cache file...")
      raise "asks cache file already exists" if File.exist?(asks_cache_file)
      ser_asks = Marshal.dump(@asks)    
      IO.binwrite(asks_cache_file, ser_asks)
    end
    
    # check if cache file exits, otherwise load .csv file
    if File.exist?(bids_cache_file)
      $logger.info("loading bids data from cache file...")
      ser_bids = IO.binread(bids_cache_file)
      @bids = Marshal.load(ser_bids)
    else
      $logger.info("loading bids data from CSV file...")
      IO.foreach(bids_data_file) do |line|
        data = line.split(",").map {|item| item.to_f}
        csv_timestamp = data[3]
        csv_bid = data[0..2]

        bid = @bids.bsearch {|time_point| time_point.time >= csv_timestamp}
        if bid.nil?
          @bids << @TimePoint.new(csv_timestamp, Array.new << csv_bid)
        else
          bid.value << csv_bid
        end      
      end
      
      # serialize array into cache file
      $logger.info("serializing bids data to cache file...")
      raise "bids cache file already exists" if File.exist?(bids_cache_file)
      ser_bids = Marshal.dump(@bids)    
      IO.binwrite(bids_cache_file, ser_bids)
    end
    
    # sort ascendingly based on time
    $logger.info("sorting database...")
    @asks.sort! {|a, b| a.time <=> b.time}
    @bids.sort! {|a, b| a.time <=> b.time}
    
    start_time = [@asks[0].time, @bids[0].time].min
    stop_time = [@asks[-1].time, @bids[-1].time].max
    @timer.set_time(start_time)
    @timer.stop_time = stop_time
    
    $logger.info("loaded data of #{((stop_time-start_time)/3600.0/24.0).round(2)} days")
  end
  
  # Resets the internal state of the exchange instance.
  def reset
    @orders = Array.new
    @balance = Array.new
    
    start_time = [@asks[0].time, @bids[0].time].min
    stop_time = [@asks[-1].time, @bids[-1].time].max
    @timer.set_time(start_time)
    @timer.stop_time = stop_time
  end
  
  # Returns the current balance on the simulated exchange.
  #
  # *Returns:*
  # +base_currency_balance+::   base currency balance
  # +quote_currency_balance+::  quote currency balance
  def get_balance
    balance_base_currency = @initial_balance_base_currency
    balance_quote_currency = @initial_balance_quote_currency
    
    past_positions = @balance.take_while {|position| position.time <= @timer.get_time}
    past_positions.each do |position|
      balance_base_currency += position.base_currency
      balance_quote_currency += position.quote_currency
    end
    
    return balance_base_currency, balance_quote_currency
  end

  # Places a market order. The order will be executed in a time interval starting at the simulated
  # time of the method call and with an interval length of maximal @+max_order_execution_time+ seconds.
  # 
  # *Params:*
  # +type+::                  specify if it's an sell or buy order (e.g. +:buy+ or +:sell+)
  # +volume+::                order volume in base currency
  # +fee_in_base_currency+::  if true, prefer fee in base currency, otherwise in quote currency
  #
  # *Returns:*
  # +transactions+:: array of transaction IDs; exactly one transaction ID is contained in the array
  def place_market_order(type, volume, fee_in_base_currency)
    order_id = @order_id_mutex.synchronize {@last_order_id += 1}
    
    order_creation_time = @timer.get_time
    order_execution_time = @timer.get_time + @max_order_execution_time*rand

    price = case type
    when :buy
      current_asks = nil
      @database_mutex.synchronize do
        raise StandardError, "database is empty" if @asks.empty?
        idx = @asks.rindex {|data_point| data_point.time <= order_execution_time}      
        current_asks = @asks[idx].value
      end
      get_buy_price_priv(volume, current_asks)
    when :sell
      current_bids = nil
      @database_mutex.synchronize do
        raise StandardError, "database is empty" if @bids.empty?      
        idx = @bids.rindex {|data_point| data_point.time <= order_execution_time}      
        current_bids = @bids[idx].value
      end
      get_sell_price_priv(volume, current_bids)
    else
      raise StandardError, "unknown order type"
    end
    
    fee_rate = @fees_taker
    fee = volume*fee_rate*price

    order = @Order.new(order_id, type, order_creation_time, order_execution_time, fee_rate, fee, fee_in_base_currency, volume, price, false)
    @orders_mutex.synchronize {@orders << order}
    update_balance(order)
    
    return [order_id]
  end
  
  # Places a limit order. The order will be executed in a time interval starting at the simulated
  # time of the method call and with an interval length of maximal @+max_order_execution_time+ seconds.
  # 
  # *Params:*
  # +type+::                  specify if it's an sell or buy order (e.g. +:buy+ or +:sell+)
  # +limit+::                 limit price
  # +volume+::                order volume in base currency
  # +fee_in_base_currency+::  if true, prefer fee in base currency, otherwise in quote currency
  #
  # *Returns:*
  # +transactions+:: array of transaction IDs; exactly one transaction ID is contained in the array 
  def place_limit_order(type, volume, limit, fee_in_base_currency)
    order_id = @order_id_mutex.synchronize {@last_order_id += 1}
    
    order_creation_time = @timer.get_time    
    
    order_execution_time = nil
    price = nil
    idx = nil
    
    case type
    when :buy
      future_asks = nil
      @database_mutex.synchronize do
        raise StandardError, "database is empty" if @asks.empty?        
        future_asks = @asks.select {|data_point| data_point.time >= order_creation_time} 
      end
      idx = future_asks.index {|data_point| get_buy_price_priv(volume, data_point.value) <= limit}
      
      if idx.nil?
        order_execution_time = Float::NAN
        price = Float::NAN
      else
        order_execution_time = future_asks[idx].time
        price = get_buy_price_priv(volume, future_asks[idx].value)
      end
    when :sell
      future_bids = nil
      @database_mutex.synchronize do
        raise StandardError, "database is empty" if @bids.empty?        
        future_bids = @bids.select {|data_point| data_point.time >= order_creation_time} 
      end
      idx = future_bids.index {|data_point| get_sell_price_priv(volume, data_point.value) >= limit}
      
      if idx.nil?
        order_execution_time = Float::NAN
        price = Float::NAN
      else
        order_execution_time = future_bids[idx].time
        price = get_sell_price_priv(volume, future_bids[idx].value)
      end
    else
      raise StandardError, "unknown order type"
    end
    
    if idx.nil?
      fee_rate = Float::NAN
      fee = Float::NAN
    else
      fee_rate = idx > 0 ? @fees_maker : @fees_taker
      fee = volume*fee_rate*price
    end
    
    order = @Order.new(order_id, type, order_creation_time, order_execution_time, fee_rate, fee, fee_in_base_currency, volume, price, false)
    @orders_mutex.synchronize {@orders << order}
    update_balance(order)
    
    return [order_id]
  end
  
  # Cancel an order.
  # 
  # *Params:*
  # +order_id+::  the order ID to be canceled (this is in fact the transaction ID)
  def cancel_order(order_id)
    order = @orders_mutex.synchronize do
      idx = @orders.index {|order| order.order_id == order_id}
      @orders[idx]
    end
    raise StandardError, "order ID not existing" if order.nil?
    
    if order.execution_time > @timer.get_time
      order.canceled = true
      order.execution_time = Float::NAN
    end
  end

  # Get the status of an order.
  # 
  # *Params:*
  # +order_id+::  the order ID for which the status is requested (this is in fact the transaction ID)
  #
  # *Returns:*
  # +OrderStatus+:: @+OrderStatus+ struct with information about the order: status (open/closed/canceled), requested volume, executed volume, fee, price, type (buy/sell)
  def get_order_status(order_id)
  
    order = @orders_mutex.synchronize do
      idx = @orders.index {|order| order.order_id == order_id}
      raise StandardError, "order ID not existing" if idx.nil?
      @orders[idx]
    end    
    
    if order.canceled
      status = :canceled
      vol = 0
      vol_exec = vol
      type = order.type
      price = 0
      fee = 0
    else
      current_time = @timer.get_time
      if current_time >= order.execution_time
        status = :closed
        vol = order.volume
        vol_exec = vol
        type = order.type
        price = order.price
        fee = order.fee
      else
        status = :open
        vol = 0
        vol_exec = vol
        type = order.type
        price = 0
        fee = 0
      end
    end
        
    return @OrderStatus.new(status, vol, vol_exec, fee, price, type)
  end
  
  # Write a plot of buy and sell prices in an HTML file
  #
  # *Params:*
  # +plot_file+:: file name of HTML output file
  def show_data(plot_file)
    plot = Nyaplot::Plot.new
    
    ask_time = Array.new
    bid_time = Array.new
    ask_price = Array.new
    bid_price = Array.new
    @asks.each do |ask|
      time = (ask.time - @asks[0].time) / (3600.0*24.0)      
      if ask_time.empty? || time - ask_time[-1] >= 600.0/(24.0*3600.0)        
        ask_time << time
        ask_price << ask.value.min {|a, b| a[0] <=> b[0]}[0]
      end
    end
    @bids.each do |bid|
      time = (bid.time - @bids[0].time) / (3600.0*24.0)
      if bid_time.empty? || time - bid_time[-1] >= 600.0/(24.0*3600.0)
        bid_time << time
        bid_price << bid.value.max {|a, b| a[0] <=> b[0]}[0]
      end
    end
    
    colors = ["#3182bd", "#31a354"]
    ask_line = plot.add(:line, ask_time, ask_price)
    bid_line = plot.add(:line, bid_time, bid_price)
    plot.x_label("time")
    plot.y_label("price")
    ask_line.color(colors[0])
    ask_line.title("asks")
    bid_line.color(colors[1])
    bid_line.title("bids")
    plot.legend(true)
    
    plot.export_html(plot_file)
  end

  private

  # Update the balance on the simulated exchange with the effects of an order.
  #
  # *Params:*
  # +order+:: @+Order+ struct representing an order
  def update_balance(order)
    case order.fee_in_base_currency
    when true
      base_currency_fee = order.fee/order.price
      quote_currency_fee = 0
    when false
      base_currency_fee = 0
      quote_currency_fee = order.fee
    else
      raise StandardError, "unknown fee setting"
    end
    
    case order.type
    when :buy
      base_currency_diff = order.volume - base_currency_fee
      quote_currency_diff = -order.volume*order.price - quote_currency_fee
    when :sell
      base_currency_diff = -order.volume - base_currency_fee
      quote_currency_diff = order.volume*order.price - quote_currency_fee
    else
      raise StandardError, "unknown order type"
    end

    @balance_mutex.synchronize do
      new_position = @BalancePosition.new(order.execution_time, base_currency_diff, quote_currency_diff)      
      insert_idx = @balance.bsearch_index {|position| position.time >= new_position.time}      
      if insert_idx.nil?
        @balance << new_position
      else
        @balance.insert(insert_idx, new_position)
      end
    end
  end
end
