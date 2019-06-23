# This is an example implementation of a trading strategy.
#
# ScroogeMcDuck strategy:
#
# place a *buy* order with @+investment+ units of the base currency if *all* of these requirements are fulfilled (i.e. open a long-position):
# * the historical maximum buy-price in the last @+max_window+ seconds is higher then the current price * @+max_level+ 
# * we fit a simple linear regression model to the buy-prices of the last @+slope_window+ seconds; the end-point (i.e. current time) of the
#   fitted line must be more than @+slope_delta+ higher than the starting point of the fitted line (i.e. current time - @+slope_window+ seconds)
# * no buy order was placed in the last @+open_position_refractory_time+ seconds
#
# place a *sell* order with @+investment+ units of the base currency if *any* of these requirements are fulfilled (i.e. close a long-position):
# * the current sell-price is higher than the original buy-price * @+sell_level+
# * we placed the buy order more than @+sell_window+ seconds ago
# * the current sell-price dropped below the original buy-price * @+stop_loss_level+ (i.e. stop-loss order)
class Strategy
  
  # Initializes the trading strategy class.
  #
  # *Params:*
  # +timer+:: Timer instance
  # +exchange+::  Exchange instance
  def initialize(timer, exchange)
    @timer = timer
    @exchange = exchange
    
    @investment = 0.002 # [base currency]
    
    # if these requirements are fulfilled, we place a sell order
    @sell_window = 3600*24*5
    @sell_level = 1.025
    @stop_loss_level = 0.97
    
    # if these requirements are fulfilled, we place a buy order
    @max_level = 1.03
    @max_window = 3600*16
    @slope_window = 3600*24*5
    @slope_delta = 400
        
    # wait this time until issuing a new buy order
    @open_position_refractory_time = 600 # [s]
    
    # warm-up phase, don't do any trading until @waiting_time seconds have past
    @waiting_time = 3600*5
    @first_call = true
    @start_time = 0
    
    @min_quote_currency_funding = 10
    
    # timeouts
    @order_timeout = 120 # [s]
    @cancel_timeout = 120 # [s]
    
    @order_placed = false
    
    # the @Position struct is used to keep track of open and closed positions
    @Position = Struct.new(:position_id, :position_status, :open_order_id, :open_time, :open_order_status, :close_order_id, :close_time, :close_order_status)
    @positions = Array.new
    @positions_mutex = Mutex.new
    @last_position_id = 0
    
    @last_open_position_time = 0
    
    @thread_list = Array.new    
  end
  
  # This is the main method of the trading strategy class. It is called from the Timer instance with a
  # certain frequency. Use this method to obtain the current and past prices from the Exchange instance
  # and place buy and sell orders.
  #
  # *Params:*
  # +time+:: the current time in seconds since the Epoch
  def tick(time)
    current_buy_price = @exchange.get_buy_price(@investment)
    current_sell_price = @exchange.get_sell_price(@investment)

    if @first_call
      @start_time = time
      @first_call = false      
    end
    return if time - @start_time < @waiting_time

    # open position
    if time >= @last_open_position_time + @open_position_refractory_time
      
      max_start = time - @max_window
      max_end = time
      max_price = @exchange.get_buy_price_history(@investment, max_start, max_end)[:price].max
      if max_price > current_buy_price*@max_level
        
        slope_start = time - @slope_window
        slope_end = time
        long_term_trend = @exchange.get_slope_buy_price(@investment, slope_start, slope_end)
        if long_term_trend*@slope_window > @slope_delta                  
          @last_open_position_time = time

          quote_currency_balance = @exchange.get_balance[1]
          if quote_currency_balance > @min_quote_currency_funding
            fee_in_base_currency = false
            buy_thread = create_buy_thread(@investment, fee_in_base_currency)
            @thread_list << buy_thread
          else
            $logger.warn("IF: insufficient funding: #{quote_currency_balance}")
          end
        end
      end
    end
    
    # close position
    open_positions = @positions_mutex.synchronize {@positions.select {|position| position.position_status == :open}}
    if open_positions.size > 0
      open_positions.each do |position|
        current_sell_price = @exchange.get_sell_price(@investment)
        
        if current_sell_price >= position.open_order_status.price*@sell_level || time > position.open_time + @sell_window || current_sell_price < position.open_order_status.price*@stop_loss_level
          if time > position.open_time + @sell_window
            $logger.info("selling position #{position.position_id} (expired)")
          elsif current_sell_price < position.open_order_status.price*@stop_loss_level
            $logger.info("selling position #{position.position_id} (stop-loss)")
          else
            $logger.info("selling position #{position.position_id} (win)")
          end
          @positions_mutex.synchronize {position.position_status = :close_pending}

          fee_in_base_currency = false
          sell_thread = create_sell_thread(@investment, fee_in_base_currency, position)
          @thread_list << sell_thread
        end
      end
    end
    
    # remove finished threads from thread list
    @thread_list.delete_if {|thread| !thread.alive?}
  end
  
  # This method closes all open positions and waits for all threads to finish.
  def finish
    # wait for threads to finish
    $logger.info("waiting for #{@thread_list.size} thread(s) to finish...")
    @thread_list.each {|thread| thread.join}
    $logger.info("done")
    
    # close all positions
    open_positions = @positions_mutex.synchronize {@positions.select {|position| position.position_status == :open}}
    open_positions.each do |position|
      $logger.info("selling position #{position.position_id} (finishing)")
      @positions_mutex.synchronize {position.position_status = :close_pending}
      
      order_id = nil
      order_status = nil
      position_status = :error
      begin
        # place sell order
        # investment = position.open_order_status.vol_exec
        fee_in_base_currency = false
        order_id = @exchange.place_market_order(:sell, @investment, fee_in_base_currency)
        raise StandardError, "one transaction ID expected, but got #{order_id.size}" if order_id.size != 1
        order_id = order_id[0]
        $logger.info("placed sell order #{order_id}")
        order_timeout, order_status = wait_for_order_status(order_id, :closed, @order_timeout)

        # check for time-out and in case cancel order
        
        if order_timeout
          $logger.warn("SOTO: sell-order time-out: order ID = #{order_id}, last status = #{order_status.status}")

          @exchange.cancel_order(order_id)
          cancel_timeout, cancel_status = wait_for_order_status(order_id, :canceled, @cancel_timeout)
          $logger.warn("SOCTO: cancel time-out: order ID = #{order_id}, last status = #{cancel_status.status}") if cancel_timeout
        else
          position_status = :closed
        end

      rescue StandardError => err
        $logger.error("error when closing position: #{err.to_s}") 
      end
      
      # close position
      @positions_mutex.synchronize do
        position.close_order_id = order_id
        position.close_time = @timer.get_time
        position.close_order_status = order_status
        position.position_status = position_status
      end
    end
  end
  
  # This method returns performance statistics and the number of errors of closed positions.
  #
  # *Params:*
  # +from_position_id+:: calculate statistics and errors only on positions newer than this position ID
  #
  # *Returns:*
  # +statistics+::        returns an array with closed positions; each array item is another array with the following items: position open time, position close time, invested volume (quote currency), returned volume (quote currency)
  # +errors+::            number of occurred errors (e.g. due to order timeouts)
  # +last_position_id+::  the ID of the newest position, use this ID for the next call of get_statistics
  def get_statistics(from_position_id)
    closed_positions = nil
    error_positions = nil
    @positions_mutex.synchronize do
      closed_positions = @positions.select {|position| position.position_status == :closed && position.position_id > from_position_id}
      error_positions = @positions.select {|position| position.position_status == :error && position.position_id > from_position_id}
    end
    
    # performance statistics
    statistics = Array.new
    for position in closed_positions
      qc_invest = position.open_order_status.vol_exec*position.open_order_status.price+position.open_order_status.fee
      qc_return = position.close_order_status.vol_exec*position.close_order_status.price-position.close_order_status.fee
      statistics << [position.open_time, position.close_time, qc_invest, qc_return]
    end
    
    # error statistics
    errors = error_positions.size
    
    # get last position id
    if closed_positions.size > 0 || errors > 0
      last_position_id = (closed_positions + error_positions).max{|a, b| a.position_id <=> b.position_id}.position_id
    else
      last_position_id = from_position_id
    end

    return statistics, errors, last_position_id
  end
  
  private
  
  # This method blocks until an order changes its status.
  #
  # *Params:*
  # +order_id+::          order or transaction ID
  # +status+::            status to wait for (e.g. +:closed+, +:canceled+)
  # +max_waiting_time+::  seconds until an timeout occurs if order does not change its status
  #
  # *Returns:*
  # +timeout+::     true if an timeout has occured, otherwise false
  # +last_status+:: last status of the order
  def wait_for_order_status(order_id, status, max_waiting_time)
    last_status = nil
    timeout = false
    start_time = @timer.get_time

    loop do
      last_status = @exchange.get_order_status(order_id)      
      
      if last_status.status == status
        break
      elsif @timer.get_time - start_time >= max_waiting_time        
        timeout = true
        break
      end

      @timer.sleep(15)
    end

    return timeout, last_status
  end
  
  # Creates a thread which places a buy market order.
  #
  # *Params:*
  # +investment+::            volume in base currency
  # +fee_in_base_currency+::  if true, prefer fee in base currency, otherwise in quote currency
  #
  # *Returns:*
  # +thread+:: the buy thread
  def create_buy_thread(investment, fee_in_base_currency)
    thread = Thread.new do
      #$logger.info("starting buy thread")

      order_id = nil
      order_status = nil
      position_status = :error
      begin
        # place buy order        
        order_id = @exchange.place_market_order(:buy, investment, fee_in_base_currency)
        raise StandardError, "one transaction ID expected, but got #{order_id.size}" if order_id.size != 1              
        order_id = order_id[0]
        $logger.info("placed buy order #{order_id}")
#        $logger.info("placed buy order #{order_id}: #{Time.at(@timer.get_time)}")
        order_timeout, order_status = wait_for_order_status(order_id, :closed, @order_timeout)

        # check for time-out and in case cancel order
        if order_timeout
          $logger.error("BOTO: buy-order time-out: order ID = #{order_id}, last status = #{order_status.status}")

          @exchange.cancel_order(order_id)
          cancel_timeout, cancel_status = wait_for_order_status(order_id, :canceled, @cancel_timeout)
          $logger.error("BOCTO: cancel time-out: order ID = #{order_id}, last status = #{cancel_status.status}") if cancel_timeout
        else
          position_status = :open
        end

      rescue StandardError => err
        $logger.error("error when opening position: #{err.to_s}")
      end

      # open position
      @positions_mutex.synchronize do
        @last_position_id += 1
        @positions << @Position.new(@last_position_id, position_status, order_id, @timer.get_time, order_status, nil, nil, nil)
      end

      $logger.info("closing buy thread")
    end
    
    return thread
  end
  
  # Creates a thread which places a sell market order.
  #
  # *Params:*
  # +investment+::            volume in base currency
  # +fee_in_base_currency+::  if true, prefer fee in base currency, otherwise in quote currency
  #
  # *Returns:*
  # +thread+:: the sell thread
  def create_sell_thread(investment, fee_in_base_currency, position)
    thread = Thread.new do
      #$logger.info("starting sell thread")

      order_id = nil
      order_status = nil
      position_status = :error
      begin
        # place sell order
        order_id = @exchange.place_market_order(:sell, investment, fee_in_base_currency)
        raise StandardError, "one transaction ID expected, but got #{order_id.size}" if order_id.size != 1
        order_id = order_id[0]
        $logger.info("placed sell order #{order_id}")
        order_timeout, order_status = wait_for_order_status(order_id, :closed, @order_timeout)

        # check for time-out and in case cancel order              
        if order_timeout
          $logger.error("SOTO: sell-order time-out: order ID = #{order_id}, last status = #{order_status.status}")

          @exchange.cancel_order(order_id)
          cancel_timeout, cancel_status = wait_for_order_status(order_id, :canceled, @cancel_timeout)
          $logger.error("SOCTO: cancel time-out: order ID = #{order_id}, last status = #{cancel_status.status}") if cancel_timeout
        else
          position_status = :closed
        end

      rescue StandardError => err
        $logger.error("error when closing position: #{err.to_s}")
      end

      # close position
      @positions_mutex.synchronize do
        position.close_order_id = order_id
        position.close_time = @timer.get_time
        position.close_order_status = order_status
        position.position_status = position_status
      end

      $logger.info("closing sell thread")
    end
    
    return thread
  end
end
