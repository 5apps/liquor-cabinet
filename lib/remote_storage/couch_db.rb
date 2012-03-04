
module RemoteStorage
  module CouchDB

    def self.included(base)
      require 'couchrest'
    end

    def authorize_request(user, category, token)
      raise "not implemented"
    end

    def get_data(user, category, key)
      raise "not implemented"
    end

    def put_data(user, category, key, data)
      raise "not implemented"
    end

    def delete_data(user, category, key)
      raise "not implemented"
    end

  end
end
