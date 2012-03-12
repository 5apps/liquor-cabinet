
module RemoteStorage
  module BackendInterface

    class NotImplemented < Exception ; end

    def get_auth_token(user, password)
      $stderr.puts "WARNING: get_auth_token() always returns 'fake-token'"
      return 'fake-token'
    end

    def authorize_request(user, category, token)
      $stderr.puts "WARNING: authorize_request() always returns true"
      return true
    end

    %w(get put delete).each do |verb|
      method_name = "#{verb}_data"
      define_method(method_name) { |*_|
        raise NotImplemented, method_name
      }
    end

    def check_categories(user, *categories)
      categories.map do |category|
        {
          :name => category,
          :exists => category_exists?(user, category)
        }
      end
    end

    def category_exists?(user, category)
      true
    end

  end
end
