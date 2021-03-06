require 'timeout'
require 'thread'
require 'io/console'

require 'expectr/error'
require 'expectr/errstr'
require 'expectr/version'

require 'expectr/child'
require 'expectr/adopt'
require 'expectr/lambda'

# Public: Expectr is an API to the functionality of Expect (see
# http://expect.nist.gov) implemented in ruby.
#
# Expectr contrasts with Ruby's built-in expect.rb by avoiding tying in with
# the IO class in favor of creating a new object entirely to allow for more
# granular control over the execution and display of the program being run.
#
# Examples
#
#   # SSH Login to another machine
#   exp = Expectr.new('ssh user@example.com')
#   exp.expect("Password:")
#   exp.send('password')
#   exp.interact!(blocking: true)
#
#   # See if a web server is running on the local host, react accordingly
#   exp = Expectr.new('netstat -ntl|grep ":80 " && echo "WEB"', timeout: 1)
#   if exp.expeect("WEB")
#     # Do stuff if we see 'WEB' in the output
#   else
#     # Do other stuff
#   end
class Expectr
  DEFAULT_TIMEOUT      = 30
  DEFAULT_FLUSH_BUFFER = true
  DEFAULT_BUFFER_SIZE  = 8192
  DEFAULT_CONSTRAIN    = false

  # Public: Gets/sets the number of seconds a call to Expectr#expect may last
  attr_accessor :timeout
  # Public: Gets/sets whether to flush program output to $stdout
  attr_accessor :flush_buffer
  # Public: Gets/sets the number of bytes to use for the internal buffer
  attr_accessor :buffer_size
  # Public: Gets/sets whether to constrain the buffer to the buffer size
  attr_accessor :constrain
  # Public: Returns the PID of the running process
  attr_reader :pid
  # Public: Returns the active buffer to match against
  attr_reader :buffer
  # Public: Returns the buffer discarded by the latest call to Expectr#expect
  attr_reader :discard

  # Public: Initialize a new Expectr object.
  # Spawns a sub-process and attaches to STDIN and STDOUT for the new process.
  #
  # cmd_args - This may be either a Hash containing arguments (described below)
  #            or a String or File Object referencing the application to launch
  #            (assuming Child interface).  This argument, if not a Hash, will
  #            be changed into the Hash { cmd: cmd_args }.  This argument will
  #            be  merged with the args Hash, overriding any arguments
  #            specified there.
  #            This argument is kept around for the sake of backward
  #            compatibility with extant Expectr scripts and may be deprecated
  #            in the future.  (default: {})
  # args     - A Hash used to specify options for the instance. (default: {}):
  #            :timeout      - Number of seconds that a call to Expectr#expect
  #                            has to complete (default: 30)
  #            :flush_buffer - Whether to flush output of the process to the
  #                            console (default: true)
  #            :buffer_size  - Number of bytes to attempt to read from
  #                            sub-process at a time.  If :constrain is true,
  #                            this will be the maximum size of the internal
  #                            buffer as well.  (default: 8192)
  #            :constrain    - Whether to constrain the internal buffer from
  #                            the sub-process to :buffer_size characters.
  #                            (default: false)
  #            :interface    - Interface Object to use when instantiating the
  #                            new Expectr object. (default: Child)
  def initialize(cmd_args = '', args = {})
    setup_instance
    parse_options(args)

    cmd_args = { cmd: cmd_args } unless cmd_args.is_a?(Hash)
    args.merge!(cmd_args)

    unless [:lambda, :adopt, :child].include?(args[:interface])
      args[:interface] = :child
    end

    self.extend self.class.const_get(args[:interface].capitalize)
    init_interface(args)

    Thread.new { output_loop }
  end

  # Public: Allow direct control of the running process from the controlling
  # terminal, acting as a pass-through for the life of the process (or until
  # the leave! method is called).
  #
  # args - A Hash used to specify options to be used for interaction.
  #        (default: {}):
  #        :flush_buffer - explicitly set @flush_buffer to the value specified
  #        :blocking     - Whether to block on this call or allow code
  #                        execution to continue (default: false)
  #
  # Returns the interaction Thread, calling #join on it if :blocking is true.
  def interact!(args = {})
    if @interact
      raise(ProcessError, Errstr::ALREADY_INTERACT)
    end

    @flush_buffer = args[:flush_buffer].nil? ? true : args[:flush_buffer]
    args[:blocking] ? interact_thread.join : interact_thread
  end

  # Public: Report whether or not current Expectr object is in interact mode.
  #
  # Returns a boolean.
  def interact?
    @interact
  end

  # Public: Cause the current Expectr object to leave interact mode.
  #
  # Returns nothing.
  def leave!
    @interact=false
  end

  # Public: Wraps Expectr#send, appending a newline to the end of the string.
  #
  # str - String to be sent to the active process. (default: '')
  #
  # Returns nothing.
  def puts(str = '')
    send str + "\n"
  end

  # Public: Begin a countdown and search for a given String or Regexp in the
  # output buffer, optionally taking further action based upon which, if any,
  # match was found.
  #
  # pattern     - Object String or Regexp representing pattern for which to
  #               search, or a Hash containing pattern -> Proc mappings to be
  #               used in cases where multiple potential patterns should map
  #               to distinct actions.
  # recoverable - Denotes whether failing to match the pattern should cause the
  #               method to raise an exception (default: false)
  #
  # Examples
  #
  #   exp.expect("this should exist")
  #   # => MatchData
  #
  #   exp.expect("this should exist") do
  #     # ...
  #   end
  #
  #   exp.expect(/not there/)
  #   # Raises Timeout::Error
  #
  #   exp.expect(/not there/, true)
  #   # => nil
  #
  #   hash = { "First possibility"  => -> { puts "option a" },
  #            "Second possibility" => -> { puts "option b" },
  #            default:             => -> { puts "called on timeout" } }
  #   exp.expect(hash)
  #
  # Returns a MatchData object once a match is found if no block is given
  # Yields the MatchData object representing the match
  # Raises TypeError if something other than a String or Regexp is given
  # Raises Timeout::Error if a match isn't found in time, unless recoverable
  def expect(pattern, recoverable = false)
    return expect_procmap(pattern) if pattern.is_a?(Hash)

    match = nil
    pattern = Regexp.new(Regexp.quote(pattern)) if pattern.is_a?(String)
    unless pattern.is_a?(Regexp)
      raise(TypeError, Errstr::EXPECT_WRONG_TYPE)
    end

    match = watch_match(pattern, recoverable)
    block_given? ? yield(match) : match
  end

  # Public: Begin a countdown and search for any of multiple possible patterns,
  # performing designated actions upon success/failure.
  #
  # pattern_map - Hash containing mappings between Strings or Regexps and
  #               procedure objects.  Additionally, an optional action,
  #               designated by :default or :timeout may be provided to specify
  #               an action to take upon failure.
  #
  # Examples
  #
  #   exp.expect_procmap({
  #     "option 1" => -> { puts "action 1" },
  #     /option 2/ => -> { puts "action 2" },
  #     :default   => -> { puts "default" }
  #   })
  #
  # Calls the procedure associated with the pattern provided.
  def expect_procmap(pattern_map)
    pattern_map, pattern, recoverable = process_procmap(pattern_map)
    match = nil

    match = watch_match(pattern, recoverable)

    pattern_map.each do |s,p|
      if s.is_a?(Regexp)
        return p.call if s.match(match.to_s)
      end
    end

    pattern_map[:default].call unless pattern_map[:default].nil?
    pattern_map[:timeout].call unless pattern_map[:timeout].nil?
    nil
  end

  # Public: Clear output buffer.
  #
  # Returns nothing.
  def clear_buffer!
    @out_mutex.synchronize do
      @buffer.clear
    end
  end

  private

  # Internal: Print buffer to $stdout if program output is expected to be
  # echoed.
  #
  # buf - String to be printed to $stdout.
  #
  # Returns nothing.
  def print_buffer(buf)
    $stdout.print buf if @flush_buffer
    $stdout.flush unless $stdout.sync
  end

  # Internal: Encode a String twice to force UTF-8 encoding, dropping
  # problematic characters in the process.
  #
  # buf  - String to be encoded.
  #
  # Returns the encoded String.
  def force_utf8(buf)
    return buf if buf.valid_encoding?
    buf.force_encoding('ISO-8859-1').encode('UTF-8', 'UTF-8', replace: nil)
  end

  # Internal: Initialize instance variables based upon arguments provided.
  #
  # args - A Hash used to specify options for the new object (default: {}):
  #        :timeout      - Number of seconds that a call to Expectr#expect has
  #                        to complete.
  #        :flush_buffer - Whether to flush output of the process to the
  #                        console.
  #        :buffer_size  - Number of bytes to attempt to read from sub-process
  #                        at a time.  If :constrain is true, this will be the
  #                        maximum size of the internal buffer as well.
  #        :constrain    - Whether to constrain the internal buffer from the
  #                        sub-process to :buffer_size.
  #
  # Returns nothing.
  def parse_options(args)
    @timeout = args[:timeout] || DEFAULT_TIMEOUT
    @buffer_size = args[:buffer_size] || DEFAULT_BUFFER_SIZE
    @constrain = args[:constrain] || DEFAULT_CONSTRAIN
    @flush_buffer = args[:flush_buffer]
    @flush_buffer = DEFAULT_FLUSH_BUFFER if @flush_buffer.nil?
  end

  # Internal: Initialize instance variables to their default values.
  #
  # Returns nothing.
  def setup_instance
    @buffer = ''
    @discard = ''
    @thread = nil
    @out_mutex = Mutex.new
    @interact = false
  end

  # Internal: Handle data from the interface, forcing UTF-8 encoding, appending
  # it to the internal buffer, and printing it to $stdout if appropriate.
  #
  # Returns nothing.
  def process_output(buf)
    force_utf8(buf)
    print_buffer(buf)

    @out_mutex.synchronize do
      @buffer << buf
      if @constrain && @buffer.length > @buffer_size
        @buffer = @buffer[-@buffer_size..-1]
      end
      @thread.wakeup if @thread
    end
  end

  # Internal: Check for a match against a given pattern until a match is found.
  # This method should be wrapped in a Timeout block or otherwise have some
  # mechanism to break out of the loop.
  #
  # pattern - String or Regexp containing the pattern for which to watch.
  #
  # Returns a MatchData object containing the match found.
  def check_match(pattern)
    match = nil
    @thread = Thread.current
    while match.nil?
      @out_mutex.synchronize do
        match = pattern.match(@buffer)
        if match.nil?
          raise Timeout::Error if @pid.zero?
          @out_mutex.sleep
        end
      end
    end
    match
  ensure
    @thread = nil
  end

  # Internal: Watch for a match within the timeout period.
  #
  # pattern     - String or Regexp object containing the pattern for which to
  #               watch.
  # recoverable - Boolean denoting whether a failure to find a match should be
  #               considered fatal.
  #
  # Returns a MatchData object if a match was found, or else nil.
  # Raises Timeout::Error if no match is found and recoverable is false.
  def watch_match(pattern, recoverable)
    match = nil

    Timeout::timeout(@timeout) do
      match = check_match(pattern)
    end

    @out_mutex.synchronize do
      @discard = @buffer[0..match.begin(0)-1]
      @buffer = @buffer[match.end(0)..-1]
    end

    match
  rescue Timeout::Error => details
    raise(Timeout::Error, details) unless recoverable
    nil
  end

  # Internal: Process a pattern to procedure mapping, producing a sanitized
  # Hash, a unified Regexp and a boolean denoting whether an Exception should
  # be raised upon timeout.
  #
  # pattern_map - A Hash containing mappings between patterns designated by
  #               either strings or Regexp objects, to procedures.  Optionally,
  #               either :default or :timeout may be mapped to a procedure in
  #               order to designate an action to take upon failure to match
  #               any other pattern.
  #
  # Returns a Hash, Regexp and boolean object.
  def process_procmap(pattern_map)
    # Normalize Hash keys, allowing only Regexps and Symbols for keys.
    pattern_map = pattern_map.reduce({}) do |c,e|
      unless e[0].is_a?(Symbol) || e[0].is_a?(Regexp)
        e[0] = Regexp.new(Regexp.escape(e[0].to_s))
      end
      c.merge(e[0] => e[1])
    end

    # Separate out non-Symbol keys and build a unified Regexp.
    regex_keys = pattern_map.keys.select { |e| e.is_a?(Regexp) }
    pattern = regex_keys.reduce("") do |c,e|
      c += "|" unless c.empty?
      c + "(#{e.source})"
    end

    recoverable = regex_keys.include?(:default) || regex_keys.include?(:timeout)

    return pattern_map, pattern, recoverable
  end
end
