
module RemoteStorage
  module CouchDB

    include RemoteStorage::BackendInterface

    DEFAULT_CONFIG = {
      :server => 'http://localhost:5984'
    }

    def self.included(base)
      require 'couchrest'
    end

    ## GET

    def get_data(user, category, key)
      log("GET[#{user}-#{category}] #{key}")
      database(user, category).
        get(key).
        as_couch_json.
        to_json
    rescue ::RestClient::ResourceNotFound
      halt 404
    end

    ## PUT

    def put_data(user, category, key, data)
      doc = build_doc(key, data)
      log("PUT[#{user}-#{category}] #{key} -> #{doc['value']}")
      database(user, category).
        save_doc(doc).
        to_json
    rescue ::RestClient::BadRequest
      $stderr.puts $!.http_body
      halt 400
    end

    ## DELETE

    def delete_data(user, category, key)
      log("DELETE[#{user}-#{category}] #{key}")
      database(user, category).
        delete_doc(build_doc(key)).
        to_json
    end

    def category_exists?(user, category)
      database(user, category).info
      return true
    rescue RestClient::ResourceNotFound, RestClient::Unauthorized
      return false
    end

    private

    ## COUCHDB

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

    ## HELPERS

    def build_doc(key, data=nil)
      doc = data ? JSON.parse(data) : {}
      doc['_id'] = key
      doc['_rev'] ||= params[:rev] if params[:rev]
      return doc
    end

    # don't want to rely on activesupport or extlib
    def symbolize_keys(hash)
      return unless hash
      hash.each_pair.inject({}) {|h, (k, v)|
        h.update(k.to_sym => v)
      }
    end

    def log(message)
      puts "[RemoteStorage::CouchDB] -- #{message}"
    end
  end
end
