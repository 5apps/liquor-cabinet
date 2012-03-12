module Configuration

  class Invalid < RuntimeError
    def initialize(message)
      super(message + " for environment #{ENV['RACK_ENV']}")
    end
  end

  def after_config_loaded(method_name=nil, &block)
    after_config_loaded_callbacks.push(block || -> { send(method_name) })
  end

  def config=(config)
    @config = config
    after_config_loaded_callbacks.each(&:call)
  end

  def config(path=File.expand_path("../config.yml", File.dirname(__FILE__)), env=ENV['RACK_ENV'])
    return @config if @config
    reload_config
  end

  def reload_config
    all_configs = YAML.load_file(path)
    self.config = all_configs[env]
  end

  # force config to be loaded.
  def configure!
    config
  end

  protected

  def after_config_loaded_callbacks
    @after_config_loaded_callbacks ||= []
  end
end
