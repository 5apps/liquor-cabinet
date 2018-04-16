require "remote_storage/rest_provider"
require "digest"
require "base64"
require "openssl"
require "webrick/httputils"

module RemoteStorage
  class S3Rest
    include RestProvider

    private

    # S3 already wraps the ETag around quotes
    def format_etag(etag)
      etag
    end

    def do_put_request(url, data, content_type)
      deal_with_unauthorized_requests do
        md5 = Digest::MD5.base64digest(data)
        authorization_headers = authorization_headers_for("PUT", md5, content_type, url)
        RestClient.put(url, data, authorization_headers.merge({ "Content-Type" => content_type, "Content-Md5" => md5}))
      end
    end

    # S3 does not return a Last-Modified response header on PUTs
    def do_put_request_and_return_etag_and_last_modified(url, data, content_type)
      res = do_put_request(url, data, content_type)
      head_res = do_head_request(url)

      return [res.headers[:etag].delete('"'), timestamp_for(head_res.headers[:last_modified])]
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

    def try_to_delete(url)
      found = true

      begin
        do_head_request(url)
      rescue RestClient::ResourceNotFound
        found = false
      end

      do_delete_request(url) if found

      return found
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
  end

end
