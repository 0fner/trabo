# Trading Bot
#
# Use this program to trade on the exchange using the specified strategy
#
# How to use the progrram:
# 1. set the parameters in the CONFIGURATION section
# 2. run the program as a service in the background (every output is written in a log file)
# 3. terminate the program by sending a 'HUP', 'INT', or 'TERM' signal
#
# Author: Patrick Ofner (patrick@ofner.science)
# License: MIT License
#
# Copyright 2019 Patrick Ofner (patrick@ofner.science)
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"),
# to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR
# OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
# DEALINGS IN THE SOFTWARE.


# CONFIGURATION START
# specify currencies using the short names used by your exchange
base_currency = "XBT"
quote_currency = "USD"

# exchange data are buffered in an internal database, so that the strategy code can access historical data
# time-interval between database updates (keep possible request limits of the exchange in mind)
database_update_interval = 30 # [s]
# exchange data older than database_max_age are deleted from the database
database_max_age = 3600*24*7 # [s]

# the frequency with which Strategy#Tick is called
fs = 1/60.0 # [Hz]

# if true, disable order placement, order status request and order cancellation on the exchange
# the corresponding exchange methods return dummy values in simulation mode
simulation_mode = false

# specify strategy file
strategy_file = "StrategyScroogeMcDuck.rb"

# files for trading statistics and number of errors, the statistic content depends on the strategy class
statistics_pos_file = "stat_pos.csv"
statistics_error_file = "stat_error.csv"

# specify Kraken API credentials file
api_secret_file = "kraken_api_secret.rb"

# specify log file
log_file = "Bot.log"
# CONFIGURATION END


# set directories
strategy_dir = "strategies"
data_dir = "data"
log_dir = "logs"
api_secret_dir = "./"

# load libs
lib_dir = "libs"
$LOAD_PATH.unshift(lib_dir) unless $LOAD_PATH.include?(lib_dir)
require "ExchangeKraken.rb"
require "Timer.rb"
require_relative File.join(strategy_dir, strategy_file)
require_relative File.join(api_secret_dir, api_secret_file)
require "logger"
#require "ruby-prof"

# initialize logger
$logger = Logger.new(File.join(log_dir, log_file))
$logger.datetime_format = '%Y-%m-%d %H:%M:%S'
$logger.level = Logger::INFO
$logger.formatter = proc {|severity, datetime, progname, msg| "#{severity} #{datetime}: #{msg}\n"}
$logger.info("initializing bot...")

# initialize threads
Thread.abort_on_exception = true
timer = Timer.new(fs)
exchange = ExchangeKraken.new(timer, base_currency, quote_currency, database_update_interval, database_max_age, simulation_mode)
timer.exchange = exchange
strategy = Strategy.new(timer, exchange)
timer.strategy = strategy

# register signal traps
run = true
trap("HUP") {run = false}
trap("INT") {run = false}
trap("TERM") {run = false}

# start threads
$logger.info("starting bot...")
exchange.start
sleep(10)
timer.start

# create and start statistics thread
statistics_mutex = Mutex.new
statistics_run = true
statistics_thread = Thread.new do
  last_position_id = 0
  $logger.info("starting statistics thread")
  while statistics_mutex.synchronize{statistics_run}
    statistics, n_error, last_position_id = strategy.get_statistics(last_position_id)
    timestamp = timer.get_time
    CSV.open(File.join(data_dir, statistics_pos_file), "ab") {|csv| statistics.each {|stat| csv << stat.push(timestamp)}}
    CSV.open(File.join(data_dir, statistics_error_file), "ab") {|csv| csv << [n_error, timestamp]}
    sleep(60)
  end
  $logger.info("stopped statistics thread")
end

# monitor threads
#RubyProf.start
while run
  if not exchange.collection_thread.alive?
    $logger.error("'collection' thread stopped unexpectedly. stopping bot...")
    run = false
  end
  if not exchange.database_thread.alive?
    $logger.error("'database' thread stopped unexpectedly. stopping bot...")
    run = false
  end
  if not timer.timer_thread.alive?
    $logger.error("'timer' thread stopped unexpectedly. stopping bot...")
    run = false
  end
  if not statistics_thread.alive?
    $logger.error("'statistics' thread stopped unexpectedly. stopping bot...")
    run = false
  end
  sleep(15)
end
#prof_result = RubyProf.stop

# initiate shutdown
$logger.info("shutdown initiated...")
exchange.stop
timer.stop
statistics_mutex.synchronize{statistics_run = false}
statistics_thread.join

$logger.info("bot stopped")
$logger.close

## save profiling results
#printer = RubyProf::CallStackPrinter.new(prof_result)
#File.open("profile_data.html", 'w') {|file| printer.print(file)}
#printer = RubyProf::FlatPrinterWithLineNumbers.new(prof_result)
#File.open("profile_data.txt", 'w') {|file| printer.print(file)}
