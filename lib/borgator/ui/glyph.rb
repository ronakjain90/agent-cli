# frozen_string_literal: true

require 'lipgloss'
require_relative 'theme'

module Borgator
  module UI
    # Renders the prompt glyph (eye + mouth) as styled lipgloss output.
    # All four (state, mouth) combinations are built once at load time, so
    # +prompt+ is a lookup rather than a render — it runs on every frame.
    module Glyph
      EYE = '◉'
      MOUTH = { closed: '▶', open: '>' }.freeze

      PROMPTS = { idle: Theme::EYE_IDLE, thinking: Theme::EYE_THINKING }.to_h do |state, colour|
        eye = Lipgloss::Style.new.foreground(colour).render(EYE)
        [state, MOUTH.transform_values { |mouth| "#{eye}#{mouth}" }.freeze]
      end.freeze

      # Returns the glyph for a (state, mouth) pair. Callers own their own
      # spacing. Unknown values raise KeyError rather than rendering blank.
      def self.prompt(state:, mouth:)
        PROMPTS.fetch(state).fetch(mouth)
      end
    end
  end
end
