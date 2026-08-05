# frozen_string_literal: true

module Borgator
  module UI
    # Drives the chomp cycle for the prompt glyph.
    #
    # The mouth is a pure function of how long the current turn has been
    # running. Bubbletea already re-renders the view at 60fps, so sampling
    # the cycle at render time is both smoother and simpler than scheduling
    # one tick message per frame — there is no frame counter, no generation
    # guard, and no second timer loop to keep in sync with the Poll clock.
    module Chomp
      # [mouth, duration_ms] for one full cycle: a long rest, two snaps,
      # then a shorter rest.
      CYCLE = [
        [:closed, 900],
        [:open,   160],
        [:closed, 160],
        [:open,   160],
        [:closed, 620]
      ].freeze

      CYCLE_MS = CYCLE.sum { |(_, duration)| duration }

      # A turn running longer than this settles into a static glyph rather
      # than chomping for its entire duration.
      QUIESCE_MS = 10_000

      # Opt-out for reduced motion, matching the AGENT_* env flag convention.
      ANIMATE = ENV['AGENT_ANIMATE'] != 'off'

      module_function

      # Milliseconds since epoch — the clock the cycle is sampled against.
      def now_ms
        (Time.now.to_f * 1000).to_i
      end

      # Returns :closed or :open for the frame the turn is currently on.
      # Falls back to :closed when animation is off, when no turn is running,
      # or once the turn has passed the quiesce deadline.
      def mouth(started_at, now = now_ms)
        return :closed unless ANIMATE && started_at

        elapsed = now - started_at
        return :closed if elapsed.negative? || elapsed > QUIESCE_MS

        offset = elapsed % CYCLE_MS
        CYCLE.each do |state, duration|
          return state if offset < duration

          offset -= duration
        end
        :closed
      end
    end
  end
end
