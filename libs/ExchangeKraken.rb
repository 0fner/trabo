require 'Exchange'
require 'thread'
require 'Kraken'

# This class is for trading on the {Kraken Exchange}[https://www.kraken.com].
class ExchangeKraken < Exchange
  attr_reader :collection_thread, :database_thread
  
  # Initializes the exchange.
  #
  # *Params:*
  # +timer+::             Timer instance
  # +base_currency+::     base currency string (e.g. "+XBT+")
  # +quote_currency+::    quote currency string (e.g. "+USD+")
  # +update_interval+::   time-interval between internal database updates with Kraken Exchange data
  # +database_max_age+::  data older than that age are deleted from the internal database (specify age in seconds)
  # +simulation_mode+::   boolean value, if true, disable order placement, order status request and order cancellation on the exchange, the corresponding exchange methods return then dummy values
  def initialize(timer, base_currency, quote_currency, update_interval, database_max_age, simulation_mode)
    super(timer, base_currency, quote_currency)
    
    @kraken = Kraken::Client.new(API_KEY, API_SECRET)
        
    @update_interval = update_interval    

    @database_max_age = database_max_age # [s]
    @database_maintance_interval = 60 # [s]
        
    @run = true
    @run_mutex = Mutex.new
    
    @last_order_id = 0
    
    @max_retry = 500
    @waiting_interval = 15 # [s]
    
    # for simulation purposes
    @simulation_mode = simulation_mode    
    @Order = Struct.new(:order_id, :type, :creation_time, :volume, :price)
    @orders = Array.new
    @orders_mutex = Mutex.new
    @last_order_id = 0
  end
  
  # Starts the data collection thread which polls the orderbook from the {Kraken Exchange}[https://www.kraken.com]
  # every @+update_interval+ seconds, and stores it in an internal database.
  # It also starts the database maintenance thread, which deletes orderbooks older than @+database_max_age+ seconds
  # from the internal database.
  def start
    # data collection thread
    @collection_thread = Thread.new do
      $logger.info("starting data collection thread")      
      begin
        t_last = @timer.get_time
        while @run_mutex.synchronize {@run}
          
          retry_counter = 0
          t1 = nil
          t2 = nil
          order_book = nil
          begin
            t1 = @timer.get_time
            order_book = @kraken.order_book(@pair_name).send(@pair_method)
            t2 = @timer.get_time
            retry_counter = 0
          rescue StandardError => err            
            if retry_counter >= @max_retry
              @run_mutex.synchronize {@run = false}
              raise err
            else
              $logger.warn("error during 'order_book' API call (attempt: #{retry_counter}). retrying...")
              retry_counter += 1
              @timer.sleep(@waiting_interval)
              retry
            end
          end
          # estimate timestamp assuming symmetric network delays
          timestamp = (t2 - t1) / 2.0 + t1
        
          # add order book to local database
          @database_mutex.synchronize do
            @asks << @TimePoint.new(timestamp, order_book.asks)
            @bids << @TimePoint.new(timestamp, order_book.bids)
          end
        
          t_diff = @timer.get_time - t_last
          if t_diff < @update_interval
            @timer.sleep(@update_interval - t_diff)
          else
            $logger.warn("requesting data from remote exchange took longer than the update interval of #{@update_interval}s")
          end
          t_last = @timer.get_time
        end
      rescue StandardError => err
        @run_mutex.synchronize {@run = false}
        $logger.error("error in collection thread: #{err.to_s}")
      end
      
      $logger.info("stopped data collection thread")
    end
    
    # database maintenance thread
    @database_thread = Thread.new do
      $logger.info("starting database maintenance thread")
      begin
        t_last = @timer.get_time
        while @run_mutex.synchronize {@run}
        
          # delete old database entries
          t_current = @timer.get_time
          @database_mutex.synchronize do
            asks_idx = @asks.bsearch_index {|ask| ask.time >= t_current - @database_max_age}
            bids_idx = @bids.bsearch_index {|bid| bid.time >= t_current - @database_max_age}
            @asks.slice!(0...asks_idx) unless asks_idx.nil?
            @bids.slice!(0...bids_idx) unless bids_idx.nil?
          end
          t_diff = @timer.get_time - t_last

          if t_diff < @database_maintance_interval
            @timer.sleep(@database_maintance_interval - t_diff)
            t_last = @timer.get_time
          else
            $logger.warn("database maintenance took longer than the maintance interval of #{@database_maintance_interval}s")
          end
        end
      rescue StandardError => err
        @run_mutex.synchronize {@run = false}
        $logger.error("error in database maintenance thread: #{err.to_s}")
      end
      
      $logger.info("stopped database maintenance thread")
    end
  end
  
  # Stops the data collection and database maintenance threads and blocks until they are finished.
  def stop
    @run_mutex.synchronize {@run = false}
    
    @collection_thread.join
    @database_thread.join
  end
  
  # Returns the current balance on the {Kraken Exchange}[https://www.kraken.com].
  #
  # *Returns:*
  # +base_currency_balance+::   base currency balance
  # +quote_currency_balance+::  quote currency balance
  def get_balance
    retry_counter = 0
    balance = nil
    begin
      balance = @kraken.balance
      retry_counter = 0
    rescue Kraken::KrakenAPIError => err            
      if retry_counter >= @max_retry              
        raise err
      else
        $logger.warn("error during 'balance' API call (attempt: #{retry_counter}). retrying...")
        retry_counter += 1
        @timer.sleep(@waiting_interval)
        retry
      end
    end

    balance[@base_currency] = balance[@base_currency].nil? ? 0 : balance[@base_currency].to_f
    balance[@quote_currency] = balance[@quote_currency].nil? ? 0 : balance[@quote_currency].to_f
    
    return balance[@base_currency], balance[@quote_currency]
  end
  
  # Places a market order. Check with get_order_status if the order has been executed.
  # 
  # *Params:*
  # +type+::                  specify if it's an sell or buy order (e.g. +:buy+ or +:sell+)
  # +volume+::                order volume in base currency
  # +fee_in_base_currency+::  if true, prefer fee in base currency, otherwise in quote currency
  #
  # *Returns:*
  # +transactions+:: array of transaction IDs; usually, exactly one transaction ID is contained in the array
  def place_market_order(type, volume, fee_in_base_currency)
    type_string = case type
    when :buy then "buy"
    when :sell then "sell"
    else
      raise StandardError, "unknown oder type: #{type.to_s}"
    end
    
    oflags = case fee_in_base_currency
    when true
      "fcib"
    when false
      "fciq"
    else
      raise StandardError, "unknown fee setting"
    end
        
    if @simulation_mode
      price = get_buy_price(1)
      @orders_mutex.synchronize do
        @last_order_id += 1        
        @orders << @Order.new(@last_order_id, type, @timer.get_time, volume, price)
      end
      descr = "#{type_string}: #{volume}@#{price}"
      tx_ids = [@last_order_id]
    else
      result = @kraken.add_order({'pair' => @pair_name, 'type' => type_string, 'ordertype' => "market", 'volume' => volume, 'oflags' => oflags})
      descr = result["descr"].map {|key,val| "#{key}: #{val}"}.join(" | ")
      tx_ids = result["txid"]
    end    
    $logger.info("placed market order: #{descr}, transaction IDs: #{tx_ids.join(",")}")

    return tx_ids
  end
  
  # Places a limit order. Check with get_order_status if the order has been executed.
  # 
  # *Params:*
  # +type+::                  specify if it's an sell or buy order (e.g. +:buy+ or +:sell+)
  # +limit+::                 limit price
  # +volume+::                order volume in base currency
  # +fee_in_base_currency+::  if true, prefer fee in base currency, otherwise in quote currency
  #
  # *Returns:*
  # +transactions+:: array of transaction IDs; usually, exactly one transaction ID is contained in the array
  def place_limit_order(type, volume, limit, fee_in_base_currency)
    type_string = case type
    when :buy then "buy"
    when :sell then "sell"
    else
      raise StandardError, "unknown oder type: #{type.to_s}"
    end

    oflags = case fee_in_base_currency
    when true
      "fcib"
    when false
      "fciq"
    else
      raise StandardError, "unknown fee setting"
    end

    if @simulation_mode
      @orders_mutex.synchronize do
        @last_order_id += 1
        @orders << @Order.new(@last_order_id, type, @timer.get_time, volume, limit)
      end
      descr = "#{type_string}: #{volume}@#{limit}"
      tx_ids = [@last_order_id]
    else
      result = @kraken.add_order({'pair' => @pair_name, 'type' => type_string, 'ordertype' => "limit", 'volume' => volume, 'price' => limit, 'oflags' => oflags})
      descr = result["descr"].map {|key,val| "#{key}: #{val}"}.join(" | ")
      tx_ids = result["txid"]
    end    
    $logger.info("placed limit order: #{descr}, transaction IDs: #{tx_ids.join(",")}")

    return tx_ids
  end
  
  # Cancel an order. Check with get_order_status if the order has been canceled.
  # 
  # *Params:*
  # +tx_id+::  the transaction ID of the order to cancel
  def cancel_order(tx_id)
    if @simulation_mode
      return 1
    end
    
    retry_counter = 0
    result = nil
    begin
      result = @kraken.cancel_order(tx_id)
      retry_counter = 0
    rescue Kraken::KrakenAPIError => err            
      if retry_counter >= @max_retry              
        raise err
      else
        $logger.warn("error during 'cancel_order' API call (attempt: #{retry_counter}). retrying...")
        retry_counter += 1
        @timer.sleep(@waiting_interval)
        retry
      end
    end
    result = @kraken.cancel_order(tx_id)
    
    return result["count"].to_f
  end
  
  # Get the status of an order.
  # 
  # *Params:*
  # +tx_id+::  the transaction ID of the order for which the status is requested
  #
  # *Returns:*
  # +OrderStatus+:: @+OrderStatus+ struct with information about the order: status (open/closed/canceled/pending/expired), requested volume, executed volume, fee, price, type (buy/sell)
  def get_order_status(tx_id)
    if @simulation_mode
      order = @orders_mutex.synchronize {@orders.find {|order| order.order_id == tx_id}}
      raise StandardError, "order not found: #{tx_id}" if order.nil?
      return @OrderStatus.new(:closed, order.volume, order.volume, 0, order.price, order.type)
    end
    
    retry_counter = 0
    order = nil
    begin
      order = @kraken.query_orders({'txid' => tx_id})
      retry_counter = 0
    rescue Kraken::KrakenAPIError => err            
      if retry_counter >= @max_retry              
        raise err
      else
        $logger.warn("error during 'query_orders' API call (attempt: #{retry_counter}). retrying...")
        retry_counter += 1
        @timer.sleep(@waiting_interval)
        retry
      end
    end

    vol = order[tx_id]["vol"].to_f
    vol_exec = order[tx_id]["vol_exec"].to_f
    fee = order[tx_id]["fee"].to_f
    price = order[tx_id]["price"].to_f
    type = case order[tx_id]["descr"]["type"]
    when "buy" then :buy
    when "sell" then :sell
    else
      raise StandardError, "unknown order type: #{order[tx_id]["descr"]["type"]}"
    end
    status = case order[tx_id]["status"]
    when "pending" then :pending
    when "open" then :open
    when "closed" then :closed
    when "canceled" then :canceled
    when "expired" then :expired
    else
      raise StandardError, "unknown order status: #{order[tx_id]["status"]}"
    end
    
    return @OrderStatus.new(status, vol, vol_exec, fee, price, type)
  end
end