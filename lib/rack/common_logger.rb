# Disable Rack logger completely
module Rack
  class CommonLogger
    def call(env)
      # do nothing
      @app.call(env)
    end
  end
end
