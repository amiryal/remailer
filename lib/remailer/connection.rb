require 'socket'
require 'eventmachine'

class Remailer::Connection < EventMachine::Connection
  # == Exceptions ===========================================================
  
  class CallbackArgumentsRequired < Exception; end

  # == Submodules ===========================================================
  
  autoload(:SmtpInterpreter, 'remailer/connection/smtp_interpreter')
  autoload(:Socks5Interpreter, 'remailer/connection/socks5_interpreter')

  # == Constants ============================================================
  
  CRLF = "\r\n".freeze
  DEFAULT_TIMEOUT = 5

  SMTP_PORT = 25
  SOCKS5_PORT = 1080
  
  NOTIFICATIONS = [
    :debug,
    :error,
    :connect
  ].freeze
  
  # == Properties ===========================================================
  
  attr_accessor :active_message
  attr_accessor :remote, :max_size, :protocol, :hostname
  attr_accessor :pipelining, :tls_support, :auth_support
  attr_accessor :timeout
  attr_accessor :options
  attr_reader :error, :error_message

  # == Extensions ===========================================================

  include EventMachine::Deferrable

  # == Class Methods ========================================================

  # Opens a connection to a specific SMTP server. Options can be specified:
  # * port => Numerical port number (default is 25)
  # * require_tls => If true will fail connections to non-TLS capable
  #   servers (default is false)
  # * username => Username to authenticate with the SMTP server (optional)
  # * password => Password to authenticate with the SMTP server (optional)
  # * use_tls => Will use TLS if availble (default is true)
  # * debug => Where to send debugging output (IO or Proc)
  # * connect => Where to send a connection notification (IO or Proc)
  # * error => Where to send errors (IO or Proc)
  # * on_connect => Called upon successful connection (Proc)
  # * on_error => Called upon connection error (Proc)
  # * on_disconnect => Called when connection is closed (Proc)
  # A block can be supplied in which case it will stand in as the :connect
  # option. The block will recieve a first argument that is the status of
  # the connection, and an optional second that is a diagnostic message.
  def self.open(smtp_server, options = nil, &block)
    options ||= { }
    options[:host] = smtp_server
    options[:port] ||= 25

    unless (options.key?(:use_tls))
      options[:use_tls] = true
    end

    if (block_given?)
      options[:connect] = block
    end
    
    host_name = smtp_server
    host_port = options[:port]
    
    if (proxy_options = options[:proxy])
      host_name = proxy_options[:host]
      host_port = proxy_options[:port] || SOCKS5_PORT
    end

    begin
      EventMachine.connect(host_name, host_port, self, options)
    rescue EventMachine::ConnectionError => e
       options[:connect].is_a?(Proc) and options[:connect].call(false, e.to_s)
       options[:on_error].is_a?(Proc) and options[:on_error].call(e.to_s)
       options[:debug].is_a?(Proc) and options[:debug].call(:error, e.to_s)
       options[:error].is_a?(Proc) and options[:error].call(:connect_error, e.to_s)
    end
  end
  
  # Warns about supplying a Proc which does not appear to accept the required
  # number of arguments.
  def self.warn_about_arguments(proc, range)
    unless (range.include?(proc.arity) or proc.arity == -1)
      STDERR.puts "Callback must accept #{[ range.min, range.max ].uniq.join(' to ')} arguments but accepts #{proc.arity}"
    end
  end

  # == Instance Methods =====================================================
  
  # EventMachine will call this constructor and it is not to be called
  # directly. Use the Remailer::Connection.open method to facilitate the
  # correct creation of a new connection.
  def initialize(options)
    # Throwing exceptions inside this block is going to cause EventMachine
    # to malfunction in a spectacular way and hide the actual exception. To
    # allow for debugging, exceptions are dumped to STDERR as a last resort.
    @options = options
    @hostname = @options[:hostname] || Socket.gethostname
    @timeout = @options[:timeout] || DEFAULT_TIMEOUT

    @messages = [ ]
  
    NOTIFICATIONS.each do |type|
      callback = @options[type]

      if (callback.is_a?(Proc))
        self.class.warn_about_arguments(callback, (2..2))
      end
    end
  
    debug_notification(:options, @options.inspect)
  
    reset_timeout!

    if (using_proxy?)
      use_socks5_interpreter!
    else
      use_smtp_interpreter!
    end
    
  rescue Object => e
    STDERR.puts "#{e.class}: #{e}"
  end
  
  # Returns true if the connection requires TLS support, or false otherwise.
  def use_tls?
    !!@options[:use_tls]
  end
  
  # Returns true if the connection has advertised TLS support, or false if
  # not availble or could not be detected. This will only work with ESMTP
  # capable servers.
  def tls_support?
    !!@tls_support
  end

  # Returns true if the connection has advertised authentication support, or
  # false if not availble or could not be detected. This will only work with
  # ESMTP capable servers.
  def auth_support?
    !!@auth_support
  end
  
  # Returns true if the connection will be using a proxy to connect, false
  # otherwise.
  def using_proxy?
    !!@options[:proxy]
  end
  
  # Returns true if the connection will require authentication to complete,
  # that is a username has been supplied in the options, or false otherwise.
  def requires_authentication?
    @options[:username] and !@options[:username].empty?
  end

  # This is used to create a callback that will be called if no more messages
  # are schedueld to be sent.
  def after_complete(&block)
    @options[:after_complete] = block
  end
  
  # Closes the connection after all of the queued messages have been sent.
  def close_when_complete!
    @options[:close] = true
  end

  # Sends an email message through the connection at the earliest opportunity.
  # A callback block can be supplied that will be executed when the message
  # has been sent, an unexpected result occurred, or the send timed out.
  def send_email(from, to, data, &block)
    if (block_given?)
      self.class.warn_about_arguments(block, 1..2)
    end
    
    message = {
      :from => from,
      :to => to,
      :data => data,
      :callback => block
    }
    
    @messages << message
    
    # If the connection is ready to send...
    if (@interpreter and @interpreter.state == :ready)
      # ...send the message right away.
      after_ready
    end
  end
  
  # Reassigns the timeout which is specified in seconds. Values equal to
  # or less than zero are ignored and a default is used instead.
  def timeout=(value)
    @timeout = value.to_i
    @timeout = DEFAULT_TIMEOUT if (@timeout <= 0)
  end
  
  # This implements the EventMachine::Connection#completed method by
  # flagging the connection as estasblished.
  def connection_completed
    @timeout_at = nil
  end
  
  # This implements the EventMachine::Connection#unbind method to capture
  # a connection closed event.
  def unbind
    @interpreter = nil

    if (@active_message)
      if (callback = @active_message[:callback])
        callback.call(nil)
      end
    end

    send_callback(:on_disconnect)
  end

  # This implements the EventMachine::Connection#receive_data method that
  # is called each time new data is received from the socket.
  def receive_data(data)
    reset_timeout!

    @buffer ||= ''
    @buffer << data

    if (@interpreter)
      @interpreter.process(@buffer) do |reply|
        debug_notification(:receive, "[#{@interpreter.label}] #{reply.inspect}")
      end
    else
      error_notification(:out_of_band, "Receiving data before a protocol has been established.")
    end
  end

  def post_init
    @timer = EventMachine.add_periodic_timer(1) do
      check_for_timeouts!
    end
  end
  
  #
  def detach
    @timer.cancel
    super
  end
  
  # Returns the current state of the active interpreter, or nil if no state
  # is assigned.
  def state
    @interpreter and @interpreter.state
  end

  # Sends a single line to the remote host with the appropriate CR+LF
  # delmiter at the end.
  def send_line(line = '')
    reset_timeout!

    send_data(line + CRLF)

    debug_notification(:send, line.inspect)
  end

  def resolve_hostname(hostname)
    # FIXME: Elminitate this potentially blocking call by using an async
    #        resolver if available.
    record = Socket.gethostbyname(hostname)
    
    # FIXME: IPv6 Support here
    debug_notification(:resolved, record && record.last.unpack('CCCC').join('.'))

    record and record.last
  rescue
    nil
  end

  # Resets the timeout time. Returns the time at which a timeout will occur.
  def reset_timeout!
    @timeout_at = Time.now + @timeout
  end
  
  # Checks for a timeout condition, and if one is detected, will close the
  # connection and send appropriate callbacks.
  def check_for_timeouts!
    return if (!@timeout_at or Time.now < @timeout_at)

    @timeout_at = nil

    if (@connected and @active_message)
      message_callback(:timeout, "Response timed out before send could complete")
      error_notification(:timeout, "Response timed out")
      debug_notification(:timeout, "Response timed out")
      send_callback(:on_error)
    elsif (!@connected)
      connect_notification(false, "Timed out before a connection could be established")
      debug_notification(:timeout, "Timed out before a connection could be established")
      error_notification(:timeout, "Timed out before a connection could be established")
      send_callback(:on_error)
    else
      send_callback(:on_disconnect)
    end

    close_connection
  end
  
  # Returns true if pipelining support has been detected on the connection,
  # false otherwise.
  def pipelining?
    !!@pipelining
  end

  # Returns true if pipelining support has been detected on the connection,
  # false otherwise.
  def tls_support?
    !!@tls_support
  end
  
  # Returns true if the connection has been closed, false otherwise.
  def closed?
    !!@closed
  end
  
  # Returns true if an error has occurred, false otherwise.
  def error?
    !!@error
  end
  
  # EventMachine: Enables TLS support on the connection.
  def start_tls
    debug_notification(:tls, "Started")
    super
  end

  # EventMachine: Closes down the connection.
  def close_connection
    send_callback(:on_disconnect)
    debug_notification(:closed, "Connection closed")
    super
    @closed = true
    @timeout_at = nil
  end
  alias_method :close, :close_connection

  # Switches to use the SOCKS5 interpreter for all subsequent communication
  def use_socks5_interpreter!
    @interpreter = Remailer::Connection::Socks5Interpreter.new(:delegate => self)
  end

  # Switches to use the SMTP interpreter for all subsequent communication
  def use_smtp_interpreter!
    @interpreter = Remailer::Connection::SmtpInterpreter.new(:delegate => self)
  end

  # Callback receiver for when the proxy connection has been completed.
  def after_proxy_connected
    use_smtp_interpreter!
  end

  def after_ready
    return if (@active_message)
    
    reset_timeout!
    
    if (@active_message = @messages.shift)
      if (@interpreter.state == :ready)
        @interpreter.enter_state(:send)
      end
    elsif (@options[:close])
      if (callback = @options[:after_complete])
        callback.call
      end
      
      @interpreter.enter_state(:quit)
    end
  end

  def after_message_sent(reply_code, reply_message)
    message_callback(reply_code, reply_message)

    @active_message = nil
  end
  
  def interpreter_entered_state(interpreter, state)
    debug_notification(:state, "#{interpreter.label.downcase}=#{state}")
  end

  def send_notification(type, code, message)
    case (callback = @options[type])
    when nil, false
      # No notification in this case
    when Proc
      callback.call(code, message)
    when IO
      callback.puts("%s: %s" % [ code.to_s, message ])
    else
      STDERR.puts("%s: %s" % [ code.to_s, message ])
    end
  end
  
  def connect_notification(code, message = nil)
    @connected = code

    send_notification(:connect, code, message || self.remote)
    send_callback(:on_connect) if (code)
  end

  def error_notification(code, message)
    @error = code
    @error_message = message

    send_notification(:error, code, message)
  end

  def debug_notification(code, message)
    send_notification(:debug, code, message)
  end

  def message_callback(reply_code, reply_message)
    if (callback = (@active_message and @active_message[:callback]))
      # The callback is screened in advance when assigned to ensure that it
      # has only 1 or 2 arguments. There should be no else here.
      case (callback.arity)
      when 2
        callback.call(reply_code, reply_message)
      when 1
        callback.call(reply_code)
      end
    end
  end
  
  def send_callback(type)
    if (callback = @options[type])
      case (callback.arity)
      when 1
        callback.call(self)
      else
        callback.call
      end
    end
  end
end
