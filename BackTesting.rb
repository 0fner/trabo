# Backtesting
#
# Use this program to backtest your strategy on test data.
#
# Collect test data (asks and bids files) with DataCollection.rb or load data from an external
# source and transform them into the correct format:
# Format of asks/bids files:
# * CSV files
# * columns: ask/bid price | volume | exchange unix timestamp | local unix timestamp
#
# How to use the program:
# 1. set the parameters in the CONFIGURATION section
# 2. run the program; you will see the final balance when the strategy execution is complete
# 3. press enter to re-run a strategy (you can change the strategy code between runs) or enter "q" and press enter to quit
#
# Note:
# the program loads data from the bids and asks files (.csv) and creates cache files (.dat) with the
# same name to allow faster loading in the future. If you change the content of the .csv files but
# not the file names, don't forget to delete the corresponding cache files!
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

# simulate the frequency with which Strategy#Tick is called
# lower is faster, however some strategies may rely on a a fixed frequency
fs = 1.0/300.0 # [Hz]

# specify asks and bids .csv files
# the must have the following format:
#   * no header
#   * delimiter is ","
#   * columns are: price, volume, exchange timestamp, local timestamp
asks_file = "kraken_ob_asks_sim.csv"
bids_file = "kraken_ob_bids_sim.csv"

# specify the strategy file
strategy_file = "StrategyScroogeMcDuck.rb"

# after each run, trading statistics are written to this file, the content depends on the strategy class
statistics_file = "strategy_performance.csv"

# a plot with the minimal asks and maximal bids over time in HTML is written to the specified HTML
# if an empty string is provided, no plot is created
plot_file = ""

# specifiy the initial balances
initial_base_balance = 0
initial_quote_balance = 1000
# CONFIGURATION END


# set directories
strategy_dir = "strategies"
data_dir = "data"

# load libs
lib_dir = "libs"
$LOAD_PATH.unshift(lib_dir) unless $LOAD_PATH.include?(lib_dir)
require "ExchangeSimulation.rb"
require "TimerSimulation.rb"
require "logger"

# initialize logger
$logger = Logger.new(STDOUT)
$logger.level = Logger::INFO
$logger.formatter = proc {|severity, datetime, progname, msg| "#{msg}\n"}
$logger.info("starting backtesting...")

# initialize exchange
Thread.abort_on_exception = true
timer = TimerSimulation.new(fs)
exchange = ExchangeSimulation.new(timer, base_currency, quote_currency, File.join(data_dir, asks_file), File.join(data_dir, bids_file))
timer.exchange = exchange

# set initial balance
exchange.initial_balance_base_currency = initial_base_balance
exchange.initial_balance_quote_currency = initial_quote_balance

# plot data to file
unless plot_file.empty?
  $logger.info("ploting price history...")
  exchange.show_data(File.join(data_dir, plot_file))
  $logger.info("done")
end

# start simulation
loop do
  begin
    load File.join(strategy_dir, strategy_file)

    strategy = Strategy.new(timer, exchange)
    timer.strategy = strategy

    $logger.info("starting simulation...")
    exchange.start
    timer.start

    exchange.stop
    timer.stop
    $logger.info("simulation finished")

    base_currency_balance, quote_currency_balance = exchange.get_balance    
    result = "result:\nbalance:\n\tbase currency: #{exchange.initial_balance_base_currency} -> #{base_currency_balance}\n\tquote currency: #{exchange.initial_balance_quote_currency} -> #{quote_currency_balance}"
    $logger.info(result)
    
    # write statistics to file
    statistics, _ , _ = strategy.get_statistics(0)
    CSV.open(File.join(data_dir, statistics_file), "wb") {|csv| statistics.each {|stat| csv << stat}}
  rescue Exception => e
    $logger.error("exception occured: #{e.message} -- #{e.backtrace.join(" | ")}")
  end
  exchange.reset

  $logger.info("waiting for enter to run simulation or 'q' + enter to quit...")
  input = gets
  break if input == "q\n"
end

$logger.info("backtesting stopped")
$logger.close
