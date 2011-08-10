module Smith
  class AgentCache < Cache

    attr_accessor :path

    def initialize(opts={})
      super()
      @path = (opts[:path].nil?) ? Smith.root_path.join('agents') : opts[:path]
      operator ->(agent_name){AgentProcess.first(:name => agent_name) || AgentProcess.new(:name => agent_name, :path => @path)}
      populate
    end

    def state(state)
      select {|a| a.state == state.to_s }
    end

    def names
      entries
    end

    alias :[] :entry

    private

    # When we start load any new data from the db.
    def populate
      AgentProcess.all.each { |a| update(a.name, a) }
    end
  end
end