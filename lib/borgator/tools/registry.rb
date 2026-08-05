# frozen_string_literal: true

require_relative 'support'

module Tools
  # Collects modular tool implementations registered via {register}.
  # Idempotent: re-requiring a tool file is safe (needed for isolated tests).
  module Registry
    @handlers = {}
    @order = []

    class << self
      def register(mod)
        name = mod::NAME
        if @handlers.key?(name)
          @handlers[name] = mod
          return mod
        end

        @handlers[name] = mod
        @order << name
        mod
      end

      def [](name)
        @handlers[name]
      end

      def registered_names
        @order.dup
      end

      def clear!
        @handlers = {}
        @order = []
      end

      def each_enabled
        return enum_for(:each_enabled) unless block_given?

        @order.each do |name|
          mod = @handlers[name]
          next if mod.const_defined?(:OPTIONAL) && mod::OPTIONAL && !Tools.web_fetch_enabled?

          yield mod
        end
      end

      def definitions
        each_enabled.map { |mod| mod::DEFINITION }
      end

      def core_definitions
        @order.filter_map do |name|
          mod = @handlers[name]
          next if mod.const_defined?(:OPTIONAL) && mod::OPTIONAL

          mod::DEFINITION
        end
      end
    end
  end
end
