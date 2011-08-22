# -*- encoding: utf-8 -*-
require 'amqp'
require 'tmpdir'
require 'logging'
require 'pathname'
require 'optimism'
require 'dm-core'
require 'securerandom'
require 'dm-yaml-adapter'
require 'extlib/string'
require 'extlib/inflection'
require 'daemons/pidfile_mp'

require_relative 'smith/config'
require_relative 'smith/logger'

module Smith
  include Logger

  class << self

    def connection
      raise RuntimeError, "You must run this in a Smith.start block" if @connection.nil?
      @connection
    end

    def on_error=(handler)
      @handler = handler
    end

    def config
      Config.get
    end

    def root_path
      Pathname.new(File.dirname(__FILE__) + '/..').expand_path
    end

    def agent_default_path
      p = Pathname.new(config.agents.default_path)
      if p.absolute?
        p
      else
        root_path.join(p)
      end
    end

    def running?
      EM.reactor_running?
    end

    def start(opts={}, &block)
      EM.epoll if EM.epoll?
      EM.kqueue if EM.kqueue?
      EM.set_descriptor_table_size(opts[:fdsize] || 1024)

      connection_settings = config.amqp.broker._child.merge({
        :on_tcp_connection_failure => method(:tcp_connection_failure_handler),
        :on_possible_authentication_failure => method(:authentication_failure_handler)
      })

      AMQP.start(connection_settings) do |connection|
        @connection = connection

        @connection.on_error do |conn, reason|
          if @handler
            @handler.call(conn, reason)
          else
            logger.error("Shutting down: #{reason.reply_code}: #{reason.reply_text}")
            EM.stop
          end
        end

        block.call
      end
    end

    def stop(immediately=false)
      if immediately
        connection.close { EM.stop }
      else
        EM.add_timer(1) { connection.close { EM.stop } }
      end
    end

    private

    def tcp_connection_failure_handler(settings)
      # Only display the following settings.
      s = settings.select { |k,v| ([:user, :pass, :vhost, :host, :port, :ssl].include?(k)) }

      logger.fatal("Cannot connect to the AMQP server.")
      logger.fatal("Is the server running and are the connection details correct?")
      logger.info("Details:")
      s.each do |k,v|
        logger.info(" Setting: %-7s%s" %  [k, v])
      end
      EM.stop
    end

    def authentication_failure_handler(settings)
      # Only display the following settings.
      s = settings.select { |k,v| [:user, :pass, :vhost, :host].include?(k) }

      logger.fatal("Authenticaton failure.")
      logger.info("Details:")
      s.each do |k,v|
        logger.info(" Setting: %-7s%s" %  [k, v])
      end
      EM.stop
    end
  end
end

require_relative 'smith/cache'
require_relative 'smith/agent'
require_relative 'smith/agent_cache'
require_relative 'smith/agent_process'
require_relative 'smith/agent_monitoring'
require_relative 'smith/command'
require_relative 'smith/messaging/encoding'
require_relative 'smith/messaging/endpoint'
require_relative 'smith/messaging/exceptions'
require_relative 'smith/messaging/receiver'
require_relative 'smith/messaging/sender'
