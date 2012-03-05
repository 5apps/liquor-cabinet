
module RemoteStorage
  module CouchDB

    include RemoteStorage::BackendInterface

    DEFAULT_CONFIG = {
      :server => 'http://localhost:5984'
    }

    def self.included(base)
      require 'couchrest'
    end

    def get_data(user, category, key)
      database(user, category).
        get(key).
        as_couch_json.
        to_json
    rescue ::RestClient::ResourceNotFound
      halt 404
    end

    def put_data(user, category, key, data)
      database(user, category).
        save_doc(build_doc(key, data)).
        to_json
    rescue ::RestClient::BadRequest
      $stderr.puts $!.http_body
      halt 400
    end

    def delete_data(user, category, key)
      database(user, category).
        delete_doc(build_doc(key)).
        to_json
    end

    private

    def build_doc(key, data=nil)
      doc = data ? JSON.parse(data) : {}
      doc['_id'] = key
      doc['_rev'] ||= params[:rev]
      return doc
    end

    def database(user, category)
      database_name = "#{user}-#{category}"
      CouchRest::Database.new(couch_server, database_name)
    end

    def couch_server
      @couch_server ||= CouchRest::Server.new(couch_config(:server))
    end

    def couch_config(key)
      (@couch_config ||= DEFAULT_CONFIG.merge(
        (symbolize_keys(LiquorCabinet.config['couchdb']) || {})
      ))[key.to_sym]
    end

    # don't want to rely on activesupport or extlib
    def symbolize_keys(hash)
      return unless hash
      hash.each_pair.inject({}) {|h, (k, v)|
        h.update(k.to_sym => v)
      }
    end
  end
end
