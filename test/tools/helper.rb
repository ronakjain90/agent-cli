# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'

require_relative '../../lib/borgator/sandbox'

# Shared harness for unit tests that load a single tool file in isolation.
module ToolTestHelper
  def in_project
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        Sandbox.instance_variable_set(:@root, File.realpath(dir))
        yield dir
      end
    end
  ensure
    Sandbox.instance_variable_set(:@root, nil)
  end
end
