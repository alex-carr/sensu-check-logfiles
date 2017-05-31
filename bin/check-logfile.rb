#! /usr/bin/env ruby
#
#   check-logfiles
#
# DESCRIPTION:
#   This plugin checks a logfile for lines containing the strings "ERROR" or "WARNING".
#   It also checks that the logfile exits and has been recently updated.
#   It will skip any lines that were read in any previous executions.
#   It maintains state regarding the number of bytes read so that it can scan from that position.
#   next time.
#
# OUTPUT:
#   plain text
#
# PLATFORMS:
#   Linux
#
# DEPENDENCIES:
#   gem: sensu-plugin
#
# LICENSE:
#   Copyright 2017 Slinglist DBA (alex.carr@slinglist.com)
#   Small portions of this file are Copyright 2011 Sonian, Inc <chefs@sonian.net>
#   Released under the same terms as Sensu (the MIT license); See LICENSE file for details.
#

require 'sensu-plugin/check/cli'
require 'fileutils'
require 'date'

class CheckLogfiles < Sensu::Plugin::Check::CLI
  BASE_DIR = '/var/cache/sensu-check-logfiles'.freeze

  option :logfile,
         description: 'The full-path to the logfile to be scanned',
         short: '-f LOGFILE_PATH',
         long: '--logfile LOGFILE_PATH'

  option :state_store,
         description: 'The directory to use for storing state files',
         short: '-s DIRECTORY_PATH',
         long: '--state-store DIRECTORY_PATH',
         default: "#{BASE_DIR}/statefiles"

  option :logfile_age,
         description: 'Specify the period in seconds where the logfile has not been updated, to raise a warning.',
         short: '-l SECONDS',
         long: '--logfile-age SECONDS',
         default: "3600"

  option :entry_age,
         description: 'Specify the period in seconds of the oldest log entry age that will be checked',
         short: '-e SECONDS',
         long: '--entry-age SECONDS',
         default: "600"

  def run
    unknown 'No log file specified' unless config[:logfile]

    # Get the current time
    @now = Time.now.to_i   # Current time in seconds since Epoch

    # Determine acceptable age times in seconds since epoch
    @accept_logfile_age = now - config[logfile_age] # logfile_age default: 3600
    @accept_entry_age = now - config[entry_age] # entry_age default: 600

    # Track total number of warnings and errors found in all logfiles
    num_warnings_overall = 0
    num_criticals_overall = 0

    # Get list of logfiles to check
    file_list = []
    file_list << config[:logfile] if config[:logfile]

    # Check each logfile
    file_list.each do |logfile|

      # Check file to see if its age is within acceptable window, otherwise raise a warning.
      file_list = File.mtime(logfile)
      num_warnings += 1 if modification_time_exceeded(logfile,file_mtime, @accept_logfile_age)

      # Search logfile for errors and warnings
      begin
        open_logfile logfile
      rescue => e
        message "Could not open file #{logfile}: #{e}"
        num_criticals = 1
      end
      num_warnings, num_criticals = search_logfile
      num_warnings_overall += num_warnings
      num_criticals_overall += num_criticals
    end

    # Report the number of warnings and errors found
    message "#{num_warnings_overall} warnings, #{num_criticals_overall} criticals."
    # Call the approriate exit method
    if num_criticals_overall > 0
      critical
    elsif num_warnings_overall > 0
      warning
    else
      ok
    end
  end

  def open_logfile(logfile)
    state_store = "/tmp/state" # config[:state_store]

    @log_file = File.open(logfile)

    @state_file = File.join(state_store, File.expand_path(logfile).sub(/^([A-Z]):\//, '\1/'))
    @bytes_to_skip = begin
      File.open(@state_file) do |file|
        file.flock(File::LOCK_SH)
        file.readline.to_i
      end
    rescue
      0
    end
  end

  def search_logfile
    logfile_size = @log_file.stat.size
    @bytes_to_skip = 0 if logfile_size < @bytes_to_skip
    bytes_read = 0
    num_warnings = 0
    num_errors = 0
    warning_str = 'WARNING'
    error_str = 'ERROR'

    # Skip previously read entries. This requires a state file for each log file to record the last read position.
    # Note that we do not account for log rotation here. The state counters must be reset upon log rotation.
    @log_file.seek(@bytes_to_skip, File::SEEK_SET) if @bytes_to_skip > 0
    
    @log_file.each_line do |line|

      # Skip lines that continue the first line of the entry
      next if line.start_with? "\t"

      # Determine timestamp of the entry
      date_str, timestamp = get_date_timestamp(line)

      # Convert the timestamp to epoch time
      entry_time = Time.parse(timestamp).to_i

      line = line.encode('UTF-8', invalid: :replace, replace: '')
      bytes_read += line.bytesize

      # Only check for errors and warnings that occur within the specified time window
      if entry_time < @entry_age
        # Check if the entry is a warning
        match_warning = line.match(warning_str)
        num_warnings += match_warning

        # Check if the entry is an error
        match_error = line.match(error_str)
        num_errors += match_error
      end
    end

    FileUtils.mkdir_p(File.dirname(@state_file))
    File.open(@state_file, File::RDWR | File::CREAT, 0644) do |file|
      file.flock(File::LOCK_EX)
      file.write(@bytes_to_skip + bytes_read)
    end
    [num_warnings, num_errors]
  end


  # Obtain the timestamp from the beginning of a single-line log entry.
  def get_date_timestamp(str)

    # Month names in MMM format
    months = '(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)'

    # Lines that explicitly start with a month have the timestamp format MMM DD HH:MM:SS (e.g. Feb 15 11:40:15)
    if str.match(months)
      date_str = str.match(/(^[A-Z][A-Z][A-Z] [0-3][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]) .*/i).captures
      timestamp = Time.parse(date_str[0]).to_i
      [date_str[0], timestamp]
    # Lines that start with a 10 digit number use epoch timestamp format
    elsif str.match(/(^\d{10} )/)
      timestamp = str.match(/(^\d{10}) .*/i).captures
      date_str = Time.at(timestamp[0].to_i).asctime
      [date_str, timestamp[0].to_i]
    # Anything else is not considered a valid log entry
    else
      ['',-1]
    end
  end

  # Check if the files modification age exceeds the acceptable age window
  def modification_time_exceeded(logfile, file_mtime, acceptable_age)
    if file_mtime <= acceptable_age
      message("Warning: logfile #{logfile} has not been modified within #{config[entry_age]} seconds.")
      return true
    end
    return false
  end

end