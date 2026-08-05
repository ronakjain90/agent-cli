# frozen_string_literal: true

require 'uri'
require 'ipaddr'
require 'resolv'
require 'net/http'

require_relative 'helpers'
require_relative 'registry'

module Tools
  module WebFetch
    extend Helpers

    NAME = 'web_fetch'
    OPTIONAL = true
    DEFINITION = {
      name: NAME,
      description:
        'Fetch a public http(s) URL and return a truncated text body (docs/API references). ' \
        'Blocks private/network-local destinations. Only available when web fetch is enabled.',
      input_schema: {
        type: 'object',
        properties: {
          url: { type: 'string', description: 'http or https URL to fetch.' },
          max_bytes: { type: 'integer',
                       description: "Max response body bytes to return (default #{WEB_FETCH_MAX_BYTES})." }
        },
        required: ['url']
      }
    }.freeze

    module_function

    def call(input)
      unless Tools.web_fetch_enabled?
        raise ArgumentError,
              'web_fetch is disabled. Relaunch with --web-fetch or set AGENT_ALLOW_WEB_FETCH=1.'
      end

      url_str = require_arg!(input, 'url')
      uri = parse_public_http_uri!(url_str)
      max = input['max_bytes']
      max = max.nil? ? WEB_FETCH_MAX_BYTES : max.to_i
      max = 1024 if max < 1024
      max = WEB_FETCH_MAX_BYTES if max > WEB_FETCH_MAX_BYTES

      body, final_uri, content_type = fetch_url(uri, max)
      text = body.to_s
      text = text.encode('UTF-8', invalid: :replace, undef: :replace, replace: '?')
      text = strip_html_to_text(text) if content_type.to_s.include?('html')

      header = "URL: #{final_uri}\nContent-Type: #{content_type}\nBytes: #{body.bytesize} (capped at #{max})\n\n"
      ["web_fetch #{final_uri.host}", header + text]
    end

    def fetch_url(uri, max_bytes)
      redirects = 0
      current = uri
      loop do
        raise ArgumentError, "too many redirects (max #{WEB_FETCH_MAX_REDIRECTS})" if redirects > WEB_FETCH_MAX_REDIRECTS

        assert_public_endpoint!(current)
        res = Net::HTTP.start(current.host, current.port,
                              use_ssl: current.scheme == 'https',
                              open_timeout: WEB_FETCH_TIMEOUT,
                              read_timeout: WEB_FETCH_TIMEOUT) do |http|
          req = Net::HTTP::Get.new(current)
          req['User-Agent'] = 'borgator/1.0'
          req['Accept'] = 'text/*, application/json, application/xml, */*;q=0.1'
          http.request(req)
        end

        if res.is_a?(Net::HTTPRedirection)
          loc = res['location'].to_s
          raise ArgumentError, 'redirect missing Location' if loc.empty?

          current = URI.join(current.to_s, loc)
          redirects += 1
          next
        end

        raise ArgumentError, "HTTP #{res.code} from #{current}" unless res.is_a?(Net::HTTPSuccess)

        body = res.body.to_s
        body = body.byteslice(0, max_bytes) if body.bytesize > max_bytes
        return [body, current, res['content-type'].to_s]
      end
    end

    def parse_public_http_uri!(url_str)
      uri = URI.parse(url_str)
      unless uri.is_a?(URI::HTTP) && uri.host
        raise ArgumentError, 'url must be an absolute http(s) URL'
      end

      uri
    rescue URI::InvalidURIError => e
      raise ArgumentError, "invalid url: #{e.message}"
    end

    def assert_public_endpoint!(uri)
      raise ArgumentError, 'url must be http(s)' unless uri.is_a?(URI::HTTP)
      raise ArgumentError, 'url host is required' if uri.host.to_s.empty?

      host = uri.host.to_s.downcase
      if host == 'localhost' || host.end_with?('.localhost') || host.end_with?('.local')
        raise ArgumentError, "refusing to fetch local host #{host.inspect}"
      end

      if ip_literal?(host)
        if private_or_reserved_ip?(host)
          raise ArgumentError, "refusing to fetch private/reserved address #{host}"
        end
        return
      end

      addrs =
        begin
          Resolv.getaddresses(host)
        rescue Resolv::ResolvError => e
          raise ArgumentError, "DNS resolution failed for #{uri.host}: #{e.message}"
        end
      raise ArgumentError, "could not resolve #{host}" if addrs.empty?

      addrs.each do |ip|
        raise ArgumentError, "refusing to fetch private/reserved address #{ip}" if private_or_reserved_ip?(ip)
      end
    end

    def ip_literal?(host)
      IPAddr.new(host)
      true
    rescue IPAddr::InvalidAddressError
      false
    end

    def private_or_reserved_ip?(ip)
      addr = IPAddr.new(ip)
      [
        IPAddr.new('0.0.0.0/8'),
        IPAddr.new('10.0.0.0/8'),
        IPAddr.new('127.0.0.0/8'),
        IPAddr.new('169.254.0.0/16'),
        IPAddr.new('172.16.0.0/12'),
        IPAddr.new('192.168.0.0/16'),
        IPAddr.new('::1/128'),
        IPAddr.new('fc00::/7'),
        IPAddr.new('fe80::/10')
      ].any? { |range| range.include?(addr) }
    rescue IPAddr::InvalidAddressError
      true
    end

    def strip_html_to_text(html)
      text = html.to_s
      text = text.gsub(%r{<script\b[^>]*>.*?</script>}mi, ' ')
      text = text.gsub(%r{<style\b[^>]*>.*?</style>}mi, ' ')
      text = text.gsub(/<[^>]+>/, ' ')
      text = text.gsub(/&nbsp;/i, ' ').gsub(/&amp;/i, '&').gsub(/&lt;/i, '<').gsub(/&gt;/i, '>')
      text.gsub(/[ \t]+/, ' ').gsub(/\n{3,}/, "\n\n").strip
    end
  end

  Registry.register(WebFetch)
end
