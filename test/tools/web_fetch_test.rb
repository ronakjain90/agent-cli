# frozen_string_literal: true

require 'uri'
require_relative 'helper'
require_relative '../../lib/borgator/tools/web_fetch'

class WebFetchUnitTest < Minitest::Test
  def teardown
    ENV.delete('AGENT_ALLOW_WEB_FETCH')
  end

  def test_disabled_by_default
    err = assert_raises(ArgumentError) do
      Tools::WebFetch.call('url' => 'https://example.com')
    end
    assert_match(/disabled/i, err.message)
  end

  def test_blocks_loopback_ip
    ENV['AGENT_ALLOW_WEB_FETCH'] = '1'
    err = assert_raises(ArgumentError) do
      Tools::WebFetch.call('url' => 'http://127.0.0.1/')
    end
    assert_match(/private|reserved|local/i, err.message)
  end

  def test_returns_body_via_stub
    ENV['AGENT_ALLOW_WEB_FETCH'] = '1'
    Tools::WebFetch.singleton_class.class_eval do
      alias_method :__orig_fetch_url, :fetch_url
      define_method(:fetch_url) do |_uri, _max|
        ['hello-from-fetch', URI('https://example.com/docs'), 'text/plain']
      end
    end

    _s, body = Tools::WebFetch.call('url' => 'https://example.com/docs')
    assert_match(/hello-from-fetch/, body)
  ensure
    Tools::WebFetch.singleton_class.class_eval do
      if private_method_defined?(:__orig_fetch_url) || method_defined?(:__orig_fetch_url)
        alias_method :fetch_url, :__orig_fetch_url
        remove_method :__orig_fetch_url
      end
    end
  end
end
