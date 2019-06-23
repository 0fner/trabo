# Class responsible to run the trading strategy with a certain frequency in simulation mode.
# This class is used for backtesting.
class TimerSimulation
  attr_accessor :exchange, :strategy, :stop_time
  
  # Initializes the Timer class.
  #
  # *Params:*
  # +sampling_rate+:: the simulated sampling rate in [Hz] with which the trading strategy is executed
  def initialize(sampling_rate)
    @fs = sampling_rate
        
    @current_time = 0
    @time_mutex = Mutex.new

    @stop_time = 0
  end
  
  # Returns the simulation time.
  #
  # *Returns:*
  # +time+:: the simulation time
  def get_time
    @time_mutex.synchronize {@current_time}
  end
  
  # Sets the simulation time.
  #
  # *Params:*
  # +time+:: the simulation time
  def set_time(time)
    @time_mutex.synchronize {@current_time = time}
  end
  
  # Suspends the execution.
  #
  # *Params:*
  # +duration+:: number of seconds to suspend the execution
  def sleep(duration)
    start_time = get_time
    Thread.pass while get_time - start_time <= duration
  end
  
  # Starts the trading strategy sampling thread. This thread calls the Strategy#tick method.
  def start
    raise "exchange object not set" if @exchange.nil?
    raise "strategy object not set" if @strategy.nil?
    
    sampling_interval = 1.0/@fs
    pass_time = 15
    last_pass_time = 0
    
    @timer_thread = Thread.new do
      while get_time <= @stop_time
        @strategy.tick(get_time)       
        @time_mutex.synchronize {@current_time += sampling_interval}
        
        if get_time > last_pass_time + pass_time
          last_pass_time = get_time
          Thread.pass
        end
      end
      
      $logger.info("finishing up")
      finishing_thread = Thread.new {@strategy.finish}      
      while finishing_thread.status == "run" || finishing_thread.status == "sleep"
        @time_mutex.synchronize {@current_time += sampling_interval}
        Thread.pass
      end
      finishing_thread.join      
      $logger.info("strategy sampling is stopped")
    end
  end

  # Stops the trading strategy sampling thread. It blocks until the thread is finished.
  def stop
    @timer_thread.join
  end
end