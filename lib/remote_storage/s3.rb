require "remote_storage/rest_provider"
require "digest"
require "base64"
require "cgi"
require "openssl"

module RemoteStorage
  class S3
    include RestProvider

    private

    def s3_signer
      signer ||= Aws::Sigv4::Signer.new(
        service: 's3',
        region: settings.s3["region"],
        access_key_id: settings.s3["access_key_id"].to_s,
        secret_access_key: settings.s3["secret_key_id"].to_s
      )
    end

    # S3 already wraps the ETag with quotes
    def format_etag(etag)
      etag
    end

    def do_put_request(url, data, content_type)
      deal_with_unauthorized_requests do
        headers = { "Content-Type" => content_type }
        auth_headers = auth_headers_for("PUT", url, headers, data)

        res = RestClient.put(url, data, headers.merge(auth_headers))

        return [
          res.headers[:etag].delete('"'),
          timestamp_for(res.headers[:date]) # S3 does not return a Last-Modified response header on PUTs
        ]
      end
    end

    def do_get_request(url, &block)
      deal_with_unauthorized_requests do
        headers = {}
        headers["Range"] = server.env["HTTP_RANGE"] if server.env["HTTP_RANGE"]
        auth_headers = auth_headers_for("GET", url, headers)
        RestClient.get(url, headers.merge(auth_headers), &block)
      end
    end

    def do_head_request(url, &block)
      deal_with_unauthorized_requests do
        auth_headers = auth_headers_for("HEAD", url)
        RestClient.head(url, auth_headers, &block)
      end
    end

    def do_delete_request(url)
      deal_with_unauthorized_requests do
        auth_headers = auth_headers_for("DELETE", url)
        RestClient.delete(url, auth_headers)
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

    def auth_headers_for(http_method, url, headers = {}, data = nil)
      signature = s3_signer.sign_request(
        http_method: http_method, url: url, headers: headers, body: data
      )
      signature.headers
    end

    def uri_escape(s)
      CGI.escape(s).gsub('%5B', '[').gsub('%5D', ']')
    end

    def base_url
      @base_url ||= settings.s3["endpoint"]
    end

    def container_url_for(user)
      "#{base_url}/#{settings.s3["bucket"]}/#{user}"
    end
  end
end
