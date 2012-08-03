# -*- encoding: utf-8 -*-

module Smith
  class Agent

    include Logger
    include Smith::ObjectCount

    attr_reader :factory, :name, :pid

    def initialize(options={})
      @name = self.class.to_s
      @pid = $$

      @factory = QueueFactory.new

      @signal_handlers = Hash.new { |h,k| h[k] = Array.new }

      setup_control_queue
      setup_stats_queue

      @start_time = Time.now

      on_started do
        logger.info { "#{name}:[#{pid}] started." }
      end

      on_stopped do
        logger.info { "#{name}:[#{pid}] stopped." }
      end

      EM.threadpool_size = 1

      acknowledge_start
      start_keep_alive
    end

    # Override this method to implement your own agent. You can use task but this may
    # go away in the future. This method must not block.
    def run
      raise ArgumentError, "You need to call Agent.task(&block)" if @@task.nil?

      logger.debug { "Setting up default queue: #{default_queue_name}" }

      subscribe(default_queue_name, :auto_delete => false) do |r|
        @@task.call(r.payload)
      end
    end

    def on_started(&blk)
      @on_started = blk
    end

    def on_stopped(&blk)
      Smith.shutdown_hook(&blk)
    end

    def install_signal_handler(signal, position=:end, &blk)
      raise ArgumentError, "Unknown position: #{position}" if ![:beginning, :end].include?(position)

      logger.verbose { "Installing signal handler for #{signal}" }
      @signal_handlers[signal].insert((position == :beginning) ? 0 : -1, blk)
      @signal_handlers.each do |sig, handlers|
        trap(sig, proc { |sig| run_signal_handlers(sig, handlers) })
      end
    end

    def started
      @on_started.call
    end

    def receiver(queue_name, opts={})
      queues.receiver(queue_name, opts) do |receiver|
        receiver.subscribe do |r|
          yield r
        end
      end
    end

    def sender(queue_name, opts={})
      queues.sender(queue_name, opts) { |sender| yield sender }
    end

    class << self
      def task(opts={}, &blk)
        @@task = blk
      end

      # Options supported:
      # :monitor,   the agency will monitor the agent & if dies restart.
      # :singleton, only every have one agent. If this is set to false
      #             multiple agents are allowed.
      def options(opts)
        Smith.config.agent._merge!(opts)
      end
    end

    protected

    def run_signal_handlers(sig, handlers)
      logger.debug { "Running signal handlers for agent: #{name}: #{sig}" }
      handlers.each { |handler| handler.call(sig) }
    end

    def setup_control_queue
      logger.debug { "Setting up control queue: #{control_queue_name}" }
      receiver(control_queue_name, :auto_delete => true, :durable => false) do |r|
        logger.debug { "Command received on agent control queue: #{r.payload.command} #{r.payload.options}" }

        case r.payload.command
        when 'object_count'
          object_count(r.payload.options.first.to_i).each{|o| logger.info{o}}
        when 'stop'
          acknowledge_stop { Smith.stop }
        when 'log_level'
          begin
            level = r.payload.options.first
            logger.info { "Setting log level to #{level} for: #{name}" }
            log_level(level)
          rescue ArgumentError => e
            logger.error { "Incorrect log level: #{level}" }
          end
        else
          logger.warn { "Unknown command: #{level} -> #{level.inspect}" }
        end
      end
    end

    def setup_stats_queue
      # instantiate this queue without using the factory so it doesn't show
      # up in the stats.
      sender('agent.stats', :dont_cache => true, :durable => false, :auto_delete => false) do |stats_queue|
        EventMachine.add_periodic_timer(2) do
          callback = proc do |consumers|
            payload = ACL::Payload.new(:agent_stats).content do |p|
              p.agent_name = self.name
              p.pid = self.pid
              p.rss = (File.read("/proc/#{pid}/statm").split[1].to_i * 4) / 1024 # This assumes the page size is 4K & is MB
              p.up_time = (Time.now - @start_time).to_i
              factory.each_queue do |q|
                p.queues << ACL::AgentStats::QueueStats.new(:name => q.denormalized_queue_name, :type => q.class.to_s, :length => q.counter)
              end
            end

            stats_queue.publish(payload)
          end

          # The errback argument is set to nil so as to suppress the default message.
          stats_queue.consumers?(callback, nil)
        end
      end
    end

    def acknowledge_start
      sender('agent.lifecycle', :auto_delete => false, :durable => false, :dont_cache => true) do |ack_start_queue|
        payload = ACL::Payload.new(:agent_lifecycle).content do |p|
          p.state = 'acknowledge_start'
          p.pid = $$
          p.name = self.class.to_s
          p.metadata = agent_options[:metadata]
          p.monitor = agent_options[:monitor]
          p.singleton = agent_options[:singleton]
          p.started_at = Time.now.to_i
        end
        ack_start_queue.publish(payload)
      end
    end

    def acknowledge_stop(&block)
      sender('agent.lifecycle', :auto_delete => false, :durable => false, :dont_cache => true) do |ack_stop_queue|
        message = {:state => 'acknowledge_stop', :pid => $$, :name => self.class.to_s}
        ack_stop_queue.publish(ACL::Payload.new(:agent_lifecycle).content(message), &block)
      end
    end

    def start_keep_alive
      if agent_options[:monitor]
        EventMachine::add_periodic_timer(1) do
          sender('agent.keepalive', :auto_delete => false, :durable => false, :dont_cache => true) do |keep_alive_queue|
            message = {:name => self.class.to_s, :pid => $$, :time => Time.now.to_i}
            keep_alive_queue.consumers? do |sender|
              keep_alive_queue.publish(ACL::Payload.new(:agent_keepalive).content(message))
            end
          end
        end
      else
        logger.info { "Not initiating keep alive, agent is not being monitored: #{@name}" }
      end
    end

    def queues
      @factory
    end

    def agent_options
      Smith.config.agent._child
    end

    def control_queue_name
      "#{default_queue_name}.control"
    end

    def default_queue_name
      "agent.#{name.sub(/Agent$/, '').snake_case}"
    end
  end
end
