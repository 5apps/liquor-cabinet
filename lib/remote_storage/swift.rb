require "rest_client"
require "active_support/core_ext/time/conversions"
require "active_support/core_ext/numeric/time"
require "active_support/core_ext/hash"
require "remote_storage/rest_provider"

module RemoteStorage
  class Swift
    include RestProvider

    private

    # Add quotes around the ETag
    def format_etag(etag)
      %Q("#{etag}")
    end

    def base_url
      @base_url ||= settings.swift["host"]
    end

    def container_url_for(user)
      "#{base_url}/rs:documents:#{settings.environment.to_s}/#{user}"
    end

    def default_headers
      {"x-auth-token" => swift_token}
    end

    def reload_swift_token
      server.logger.debug "Reloading swift token. Old token: #{settings.swift_token}"
      # Remove the line break from the token file. The line break that the
      # token script is adding to the file was causing Sentry to reject the
      # token field
      settings.swift_token           = File.read(swift_token_path).rstrip
      settings.swift_token_loaded_at = Time.now
      server.logger.debug "Reloaded swift token. New token: #{settings.swift_token}"
    end

    def swift_token_path
      "tmp/swift_token.txt"
    end

    def swift_token
      reload_swift_token if Time.now - settings.swift_token_loaded_at > 1800

      settings.swift_token
    end

    def deal_with_unauthorized_requests(&block)
      begin
        block.call
      rescue RestClient::Unauthorized => ex
        Raven.capture_exception(
          ex,
          tags: { swift_token:           settings.swift_token[0..19], # send the first 20 characters
                  swift_token_loaded_at: settings.swift_token_loaded_at }
        )
        server.halt 500
      end
    end
  end
end
