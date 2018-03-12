require "aws-sdk"
require "redis"
require "active_support/core_ext/time/conversions"
require "active_support/core_ext/numeric/time"
require "remote_storage/redis_provider"

module RemoteStorage
  class S3
    include RedisProvider

    attr_accessor :settings, :server

    def initialize(settings, server)
      @settings = settings
      @server = server

      Aws.config.update({
        endpoint: settings.s3["endpoint"],
        region: settings.s3["region"],
        credentials: Aws::Credentials.new(settings.s3["access_key_id"], settings.s3["secret_key_id"])
      })
    end

    def get_head(user, directory, key)
      url = url_for_key(user, directory, key)

      object = bucket.object(url)

      server.halt 404 unless object.exists?

      set_response_headers(object)
    end

    def get_data(user, directory, key)
      url = url_for_key(user, directory, key)

      object = bucket.object(url)
      server.halt 404, "Not Found" unless object.exists?

      set_response_headers(object)

      none_match = (server.env["HTTP_IF_NONE_MATCH"] || "").split(",")
                                                           .map(&:strip)
                                                           .map { |s| s.gsub(/^"?W\//, "") }
      server.halt 304 if none_match.include? %Q("#{object.etag}")

      return object.get.body
    end

    def put_data(user, directory, key, data, content_type)
      server.halt 400 if server.env["HTTP_CONTENT_RANGE"]
      server.halt 409 if has_name_collision?(user, directory, key)

      existing_metadata = redis.hgetall redis_metadata_object_key(user, directory, key)
      url = url_for_key(user, directory, key)
      object = bucket.object(url)

      if required_match = server.env["HTTP_IF_MATCH"]
        required_match = required_match.gsub(/^"?W\//, "")
        unless required_match == %Q("#{existing_metadata["e"]}")

          # get actual metadata and compare in case redis metadata became out of sync
          server.halt 412, "Precondition Failed" unless object.exists?

          if required_match == %Q("#{object.etag}")
            # log previous size difference that was missed ealier because of redis failure
            log_size_difference(user, existing_metadata["s"], object.content_length)
          else
            server.halt 412, "Precondition Failed"
          end
        end
      end
      if server.env["HTTP_IF_NONE_MATCH"] == "*"
        server.halt 412, "Precondition Failed" unless existing_metadata.empty?
      end

      object.put(body: data, content_type: content_type)

      etag = object.etag
      timestamp = object.last_modified

      metadata = {
        e: etag,
        s: data.size,
        t: content_type,
        m: timestamp.to_s
      }

      if update_metadata_object(user, directory, key, metadata)
        if metadata_changed?(existing_metadata, metadata)
          update_dir_objects(user, directory, timestamp, checksum_for(data))
          log_size_difference(user, existing_metadata["s"], metadata[:s])
        end

        server.headers["ETag"] = %Q("#{etag}")
        server.halt existing_metadata.empty? ? 201 : 200
      else
        server.halt 500
      end
    end

    def delete_data(user, directory, key)
      url = url_for_key(user, directory, key)
      object = bucket.object(url)

      not_found = !object.exists?

      existing_metadata = redis.hgetall "rs:m:#{user}:#{directory}/#{key}"

      if required_match = server.env["HTTP_IF_MATCH"]
        unless required_match.gsub(/^"?W\//, "") == %Q("#{existing_metadata["e"]}")
          server.halt 412, "Precondition Failed"
        end
      end

      object.delete

      log_size_difference(user, existing_metadata["s"], 0)
      delete_metadata_objects(user, directory, key)
      delete_dir_objects(user, directory)

      if not_found
        server.halt 404, "Not Found"
      else
        server.headers["Etag"] = %Q("#{existing_metadata["e"]}")
        server.halt 200
      end
    end

    private

    def set_response_headers(object)
      server.headers["ETag"]           = object.etag
      server.headers["Content-Type"]   = object.content_type
      server.headers["Content-Length"] = object.content_length.to_s
      server.headers["Last-Modified"]  = object.last_modified.httpdate
    end

    def resource
      # FIXME: Setting the signature_version to s3 is required for Exoscale SOS
      # to work
      @resource ||= Aws::S3::Resource.new(signature_version: 's3')
    end

    def bucket
      @bucket ||= begin
                    resource.bucket(settings.s3["bucket"])
                  end
    end

    def url_for_key(user, directory, key)
      File.join [escape(user), escape(directory), escape(key)].compact
    end
  end
end
