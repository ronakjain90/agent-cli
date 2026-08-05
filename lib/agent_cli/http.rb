# frozen_string_literal: true

require 'json'
require 'net/http'
require 'fileutils'
require 'time'

module HTTP
  LOG_DIR = 'log'
  USER_AGENT = 'agent-cli/1.0'

  class << self
    def debug_enabled
      return true if @debug_enabled == true
      return false unless @debug_enabled.nil?

      ENV['AGENT_DEBUG'] == '1'
    end

    attr_writer :debug_enabled

    def open_log
      return nil unless debug_enabled == true

      FileUtils.mkdir_p(LOG_DIR)
      path = File.join(LOG_DIR, "agent-cli-#{Time.now.strftime('%Y%m%d-%H%M%S')}.log")
      File.open(path, 'a')
    end

    # Pretty-print a JSON body, falling back to the raw string.
    def format_body(body)
      return '(empty)' if body.nil? || body.to_s.empty?

      parsed = JSON.parse(body.to_s)
      JSON.pretty_generate(parsed)
    rescue JSON::ParserError
      body.to_s
    end

    # Mask sensitive header values (API keys, tokens, secrets) so logs are safe
    # to share.
    def mask_secret(value)
      s = value.to_s
      return s if s.empty?

      "#{s[0, 4]}…#{s[-4, 4]}"
    end

    SENSITIVE_HEADER = /api.?key|authorization|token|secret/i

    def sensitive_header?(name)
      name.to_s.match?(SENSITIVE_HEADER)
    end

    # Log a full request/response envelope. Sensitive headers are masked.
    # Flushed per entry so nothing needs to close the handle — closing between
    # turns is what made the next turn's write raise `IOError: closed stream`.
    def log!(handle, label, uri, headers, body, response_status, response_body)
      return if handle.nil? || handle.closed?

      handle.puts('=' * 70)
      handle.puts("[#{Time.now.iso8601}] #{label}")
      handle.puts("[#{Time.now.iso8601}] URI: #{uri}")
      handle.puts("[#{Time.now.iso8601}] Request headers:")
      headers.each do |k, v|
        v = mask_secret(v) if sensitive_header?(k)
        handle.puts("  #{k}: #{v}")
      end
      handle.puts("[#{Time.now.iso8601}] Request body:")
      handle.puts(format_body(body))
      handle.puts("[#{Time.now.iso8601}] Response status: #{response_status}")
      handle.puts("[#{Time.now.iso8601}] Response body:")
      handle.puts(format_body(response_body))
      handle.puts
      handle.flush
    end

    # Execute an HTTP request with debug logging. Returns the Net::HTTPResponse.
    #
    # @param uri [URI] the endpoint
    # @param method [Symbol] :post or :get
    # @param body [String, nil] JSON request body
    # @param headers [Hash{String=>String}] request headers
    # @param read_timeout [Integer] seconds
    # @param log_label [String] label written into the log
    # @param log_handle [IO, nil] open log file handle (from {open_log})
    # @return [Net::HTTPResponse]
    def request(uri, method: :post, body: nil, headers: {}, read_timeout: 120, log_label: 'HTTP', log_handle: nil)
      req =
        case method
        when :post
          Net::HTTP::Post.new(uri)
        when :get
          Net::HTTP::Get.new(uri)
        else
          raise ArgumentError, "unsupported HTTP method #{method}"
        end

      headers.each { |k, v| req[k] = v }
      req.body = body if body

      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', read_timeout: read_timeout) do |http|
        http.request(req)
      end

      log!(log_handle, log_label, uri.to_s, req.each_header.to_h, body, res.code, res.body)
      res
    end
  end
end
