require "digest"
require "base64"
require "openssl"
require "webrick/httputils"

module RemoteStorage
  class S3Rest < Swift

    def get_data(user, directory, key)
      url = url_for_key(user, directory, key)

      res = do_get_request(url)

      set_response_headers(res)

      none_match = (server.env["HTTP_IF_NONE_MATCH"] || "").split(",")
                                                           .map(&:strip)
                                                           .map { |s| s.gsub(/^"?W\//, "") }
      # The Etag from an S3 compatible API is surrounded by quotes
      server.halt 304 if none_match.include? res.headers[:etag]

      return res.body
    rescue RestClient::ResourceNotFound
      server.halt 404, "Not Found"
    end

    def put_data(user, directory, key, data, content_type)
      server.halt 400 if server.env["HTTP_CONTENT_RANGE"]
      server.halt 409, "Conflict" if has_name_collision?(user, directory, key)

      existing_metadata = redis.hgetall redis_metadata_object_key(user, directory, key)
      url = url_for_key(user, directory, key)

      if required_match = server.env["HTTP_IF_MATCH"]
        required_match = required_match.gsub(/^"?W\//, "")
        unless required_match == %Q("#{existing_metadata["e"]}")

          # get actual metadata and compare in case redis metadata became out of sync
          begin
            head_res = do_head_request(url)
          # The file doesn't exist in S3, return 412
          rescue RestClient::ResourceNotFound
            server.halt 412, "Precondition Failed"
          end

          # The Etag from an S3 compatible API is surrounded by quotes, remove them
          if required_match == head_res.headers[:etag]
            # log previous size difference that was missed ealier because of redis failure
            log_size_difference(user, existing_metadata["s"], head_res.headers[:content_length])
          else
            server.halt 412, "Precondition Failed"
          end
        end
      end
      if server.env["HTTP_IF_NONE_MATCH"] == "*"
        server.halt 412, "Precondition Failed" unless existing_metadata.empty?
      end

      res = do_put_request(url, data, content_type)
      # The S3 API returns the ETag, but not the Last-Modified header on A PUT
      head_res = do_head_request(url)

      timestamp = timestamp_for(head_res.headers[:last_modified])

      metadata = {
        # The Etag from an S3 compatible API is surrounded by quotes, remove them
        e: res.headers[:etag].delete('"'),
        s: data.size,
        t: content_type,
        m: timestamp
      }

      if update_metadata_object(user, directory, key, metadata)
        if metadata_changed?(existing_metadata, metadata)
          update_dir_objects(user, directory, timestamp, checksum_for(data))
          log_size_difference(user, existing_metadata["s"], metadata[:s])
        end

        server.headers["ETag"] = res.headers[:etag]
        server.halt existing_metadata.empty? ? 201 : 200
      else
        server.halt 500
      end
    end

    def delete_data(user, directory, key)
      url = url_for_key(user, directory, key)
      not_found = false

      # S3 returns a 200 on a delete request on an object that does not exist
      begin
        do_head_request(url)
      rescue RestClient::ResourceNotFound
        not_found = true
      end

      existing_metadata = redis.hgetall "rs:m:#{user}:#{directory}/#{key}"

      if required_match = server.env["HTTP_IF_MATCH"]
        unless required_match.gsub(/^"?W\//, "") == %Q("#{existing_metadata["e"]}")
          server.halt 412, "Precondition Failed"
        end
      end

      do_delete_request(url) unless not_found

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

    def set_response_headers(response)
      # The Etag from an S3 compatible API is already surrounded by quotes
      server.headers["ETag"]           = response.headers[:etag]
      server.headers["Content-Type"]   = response.headers[:content_type]
      server.headers["Content-Length"] = response.headers[:content_length]
    end

    def do_put_request(url, data, content_type)
      deal_with_unauthorized_requests do
      md5 = Digest::MD5.base64digest(data)
      authorization_headers = authorization_headers_for("PUT", md5, content_type, url)
      RestClient.put(url, data, authorization_headers.merge({ "Content-Type" => content_type, "Content-Md5" => md5}))
      end
    end

    def do_get_request(url, &block)
      deal_with_unauthorized_requests do
        authorization_headers = authorization_headers_for("GET", "", "", url)
        RestClient.get(url, authorization_headers, &block)
      end
    end

    def do_head_request(url, &block)
      deal_with_unauthorized_requests do
        authorization_headers = authorization_headers_for("HEAD", "", "", url)
        RestClient.head(url, authorization_headers, &block)
      end
    end

    def do_delete_request(url)
      deal_with_unauthorized_requests do
        authorization_headers = authorization_headers_for("DELETE", "", "", url)
        RestClient.delete(url, authorization_headers)
      end
    end

    def authorization_headers_for(http_verb, md5, content_type, url)
      url = File.join("/", url.gsub(base_url, ""))
      date = Time.now.httpdate
      signed_data = signature(http_verb, md5, content_type, date, url)
      { "Authorization" => "AWS #{credentials[:access_key_id]}:#{signed_data}",
        "Date" => date}
    end

    def credentials
      @credentials ||= { access_key_id: settings.s3["access_key_id"], secret_key_id: settings.s3["secret_key_id"] }
    end

    def digest(secret, string_to_sign)
      Base64.encode64(hmac(secret, string_to_sign)).strip
    end

    def hmac(key, value)
      OpenSSL::HMAC.digest(OpenSSL::Digest.new('sha1'), key, value)
    end

    def uri_escape(s)
      WEBrick::HTTPUtils.escape(s).gsub('%5B', '[').gsub('%5D', ']')
    end

    def signature(http_verb, md5, content_type, date, url)
      string_to_sign = [http_verb, md5, content_type, date, url].join "\n"
      signature = digest(credentials[:secret_key_id], string_to_sign)
      uri_escape(signature)
    end

    def base_url
      @base_url ||= settings.s3["endpoint"]
    end

    def container_url_for(user)
      "#{base_url}#{settings.s3["bucket"]}/#{user}"
    end

    def deal_with_unauthorized_requests(&block)
      begin
        block.call
      rescue RestClient::Unauthorized => ex
        Raven.capture_exception(ex)
        server.halt 500
      end
    end
  end

end
