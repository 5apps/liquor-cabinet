require "remote_storage/rest_provider"
require "digest"
require "base64"
require "openssl"
require "webrick/httputils"

module RemoteStorage
  class S3
    include RestProvider

    private

    # S3 already wraps the ETag around quotes
    def format_etag(etag)
      etag
    end

    def do_put_request(url, data, content_type)
      validate_content_type(content_type)

      deal_with_unauthorized_requests do
        md5 = Digest::MD5.base64digest(data)
        authorization_headers = authorization_headers_for(
          "PUT", url, md5, content_type
        ).merge({ "Content-Type" => content_type, "Content-Md5" => md5 })
        res = RestClient.put(url, data, authorization_headers)

        return [
          res.headers[:etag].delete('"'),
          timestamp_for(res.headers[:date]) # S3 does not return a Last-Modified response header on PUTs
        ]
      end
    end

    def do_get_request(url, &block)
      deal_with_unauthorized_requests do
        headers = { }
        headers["Range"] = server.env["HTTP_RANGE"] if server.env["HTTP_RANGE"]
        authorization_headers = authorization_headers_for("GET", url)
        RestClient.get(url, authorization_headers.merge(headers), &block)
      end
    end

    def do_head_request(url, &block)
      deal_with_unauthorized_requests do
        authorization_headers = authorization_headers_for("HEAD", url)
        RestClient.head(url, authorization_headers, &block)
      end
    end

    def do_delete_request(url)
      deal_with_unauthorized_requests do
        authorization_headers = authorization_headers_for("DELETE", url)
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

    # This is using the S3 authorizations, not the newer AW V4 Signatures
    # (https://s3.amazonaws.com/doc/s3-developer-guide/RESTAuthentication.html)
    def authorization_headers_for(http_verb, url, md5 = nil, content_type = nil)
      url = File.join("/", url.gsub(base_url, ""))
      date = Time.now.httpdate
      signed_data = generate_s3_signature(http_verb, md5, content_type, date, url)
      {
        "Authorization" => "AWS #{credentials[:access_key_id]}:#{signed_data}",
        "Date" => date
      }
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

    def generate_s3_signature(http_verb, md5, content_type, date, url)
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
