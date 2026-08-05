# frozen_string_literal: true

require 'mutex_m'
require 'securerandom'

# Thread-safe Publish-Subscribe message broker for communication between
# planner (manager) and worker agents, as well as UI event streaming.
module PubSub
  class Subscription
    attr_reader :id, :pattern, :subscriber_id, :block

    def initialize(id, pattern, subscriber_id, block)
      @id = id
      @pattern = pattern.to_s
      @subscriber_id = subscriber_id
      @block = block
    end

    def matches?(channel)
      ch = channel.to_s
      return true if ['*', ch].include?(pattern)

      File.fnmatch?(pattern, ch, File::FNM_EXTGLOB | File::FNM_CASEFOLD)
    rescue StandardError
      pattern == ch
    end

    def notify(channel, payload)
      block.call(channel, payload)
    rescue StandardError => e
      warn "[PubSub Error] Subscriber #{id} failed on channel #{channel}: #{e.message}"
    end
  end

  class << self
    def mutex
      @mutex ||= Mutex.new
    end

    def subscribers
      @subscribers ||= {}
    end

    def history_list
      @history_list ||= []
    end

    # Subscribe to a channel or wildcard pattern (e.g. "planner", "worker:*", "*").
    # Accepts a block that receives (channel, payload).
    # Returns the subscription_id string.
    def subscribe(pattern = '*', subscriber_id = nil, &block)
      raise ArgumentError, 'Block required to subscribe' unless block_given?

      sub_id = SecureRandom.uuid
      sub = Subscription.new(sub_id, pattern, subscriber_id, block)

      mutex.synchronize do
        subscribers[sub_id] = sub
      end

      sub_id
    end

    # Unsubscribe by subscription_id.
    def unsubscribe(subscription_id)
      mutex.synchronize do
        subscribers.delete(subscription_id)
      end
    end

    # Publish a payload/message to a given channel.
    # Returns the list of subscriber IDs that were notified.
    def publish(channel, payload)
      ch = channel.to_s
      msg_entry = {
        channel: ch,
        payload: payload,
        timestamp: Time.now
      }

      targets = []
      mutex.synchronize do
        history_list << msg_entry
        # Keep history to a manageable size (e.g. max 1000 messages)
        history_list.shift if history_list.size > 1000

        targets = subscribers.values.select { |sub| sub.matches?(ch) }
      end

      targets.each { |sub| sub.notify(ch, payload) }
      targets.map(&:id)
    end

    # Retrieve published history, optionally filtered by channel/pattern.
    def history(channel = nil, limit: 50)
      mutex.synchronize do
        list = if channel
                 ch = channel.to_s
                 history_list.select { |m| m[:channel] == ch || File.fnmatch?(ch, m[:channel], File::FNM_EXTGLOB) }
               else
                 history_list.dup
               end
        limit ? list.last(limit) : list
      end
    end

    # Reset all subscribers and message history.
    def clear
      mutex.synchronize do
        subscribers.clear
        history_list.clear
      end
    end

    alias reset clear

    # Count of active subscribers matching channel
    def subscriber_count(channel = nil)
      mutex.synchronize do
        return subscribers.size unless channel

        ch = channel.to_s
        subscribers.values.count { |sub| sub.matches?(ch) }
      end
    end
  end
end
