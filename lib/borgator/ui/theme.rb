# frozen_string_literal: true

module Borgator
  module UI
    # Centralised colour constants used by the prompt glyph and other
    # UI elements. Keeping them in one place makes it easy to theme
    # the glyph independently of the rest of the TUI.
    module Theme
      EYE_THINKING = '#FFB800' # amber
      EYE_IDLE     = '#FAFAFA' # near-white
    end
  end
end
