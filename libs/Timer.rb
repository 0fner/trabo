# Class responsible to run the trading strategy with a certain frequency.
class Timer
  attr_reader :timer_thread
  attr_accessor :exchange, :strategy
  
  # Initializes the Timer class.
  #
  # *Params:*
  # +sampling_rate+:: the sampling rate in [Hz] with which the trading strategy is executed
  def initialize(sampling_rate)
    @fs = sampling_rate
    
    @run = true
    @run_mutex = Mutex.new
    
    @time_mutex = Mutex.new
  end
  
  # Returns the current time.
  #
  # *Returns:*
  # +time+:: the current time
  def get_time
    @time_mutex.synchronize {Time.now.to_f}
  end
  
  # Suspends the execution.
  #
  # *Params:*
  # +duration+:: number of seconds to suspend the execution
  def sleep(duration)
    Kernel.sleep(duration)
  end
  
  # Starts the trading strategy sampling thread. This thread calls the Strategy#tick method.
  def start
    raise "exchange object not set" if @exchange.nil?
    raise "strategy object not set" if @strategy.nil?
    
    sampling_interval = 1.0/@fs
    
    @timer_thread = Thread.new do
      $logger.info("starting strategy sampling thread")
      
      # do strategy sampling
      begin
        t_last = get_time
        while @run_mutex.synchronize {@run}
          @strategy.tick(get_time)        
          t_diff = get_time - t_last
          if t_diff < sampling_interval
            sleep(sampling_interval - t_diff)            
          else
            $logger.warn("strategy execution took longer than the sampling interval of #{sampling_interval}s: t = #{t_diff.round(1)}s")
          end
          t_last = get_time
        end
      rescue StandardError => err
        @run_mutex.synchronize {@run = false}
        $logger.error("error during strategy sampling: #{err.to_s}: #{err.backtrace}")
      end
      
      # finish operations
      begin
        $logger.info("finishing up")
        @strategy.finish      
      rescue StandardError => err
        $logger.error("error during strategy finishing: #{err.to_s}")
      end
      
      $logger.info("stopped strategy sampling")
    end
  end

  # Stops the trading strategy sampling thread. It blocks until the thread is finished.
  def stop
    @run_mutex.synchronize {@run = false}
    @timer_thread.join
  end
end