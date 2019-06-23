# Data Collection Service
#
# Use this program to collect trading data from an exchange (asks, bids, recent trades)
# and store them in .csv files
#
# How to use the program:
# 1. set the parameters in the CONFIGURATION section
# 2. run the program as a service in the background (every output is written in a log file)
# 3. terminate the program by sending a 'INT', or 'TERM' signal
#
# Format of asks/bids files:
# * CSV files
# * columns: ask/bid price | volume | exchange unix timestamp | local unix timestamp
#
# Format of recent trades file:
# * CSV file
# * columns: price, volume, exchange unix timestamp, b(uy)/s(ell) flag, m(arket)/l(imit) flag, miscellaneous
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

# time-interval between exchange data requests (keep request limits of the exchange in mind)
check_interval = 30 # [s]

# specify the .csv files to store asks, bids and recent trades
asks_csv_file = "kraken_ob_asks.csv"
bids_csv_file = "kraken_ob_bids.csv"
trades_csv_file = "kraken_trades.csv"

# specify log file
log_file = "DataCollection.log"
# CONFIGURATION END


# set directories
data_dir = "data"
log_dir = "logs"

# load libs
lib_dir = "libs"
$LOAD_PATH.unshift(lib_dir) unless $LOAD_PATH.include?(lib_dir)
require 'Kraken'

# initialize logger
$logger = Logger.new(File.join(log_dir, log_file))
$logger.datetime_format = '%Y-%m-%d %H:%M:%S'
$logger.level = Logger::INFO
$logger.formatter = proc {|severity, datetime, progname, msg| "#{severity} #{datetime}: #{msg}\n"}
$logger.info("running data collection deamon...")

kraken = Kraken::Client.new

pair_name = "#{base_currency}#{quote_currency}"
pair_method = "X#{base_currency}Z#{quote_currency}"

run = true

# start collector thread
collector_thread = Thread.new do

  begin
    last_trade_id = nil
    while run
      t_last = Time.now

      # get order book
      time1 = Time.now
      order_book = kraken.order_book(pair_name).send(pair_method)
      time2 = Time.now
      timestamp = (time2.to_f - time1.to_f) / 2 + time1.to_f
      # csv: price, volume, kraken timestamp, local timestamp
      CSV.open(File.join(data_dir, asks_csv_file), "ab") {|csv| order_book.asks.each {|data| csv << data.push(timestamp)}}
      CSV.open(File.join(data_dir, bids_csv_file), "ab") {|csv| order_book.bids.each {|data| csv << data.push(timestamp)}}

      # get trades
      if last_trade_id.nil?
        result = kraken.trades(pair_name)
      else
        result = kraken.trades(pair_name, {'since' => last_trade_id})
      end
      trades = result.send(pair_method)
      last_trade_id = result.last
      # csv: price, volume, time, buy/sell, market/limit, miscellaneous
      CSV.open(File.join(data_dir, trades_csv_file), "ab") {|csv| trades.each {|data| csv << data}}

      t_diff = Time.now - t_last
      if t_diff < check_interval
        sleep(check_interval - t_diff)
      else
        $logger.warn("getting data took longer than the check interval of #{check_interval}s: t = #{t_diff.round(1)}s")
      end
    end

  rescue Exception => err
    $logger.error("exception occured: #{err.message}")
    sleep(10)
    retry
  end
end

trap("INT") {run = false}
trap("TERM") {run = false}

collector_thread.join
$logger.info("data collection stopped")
$logger.close
