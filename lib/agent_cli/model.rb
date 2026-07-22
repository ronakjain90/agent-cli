# frozen_string_literal: true

# A selectable model in the picker (or the "other…" escape hatch).
class Model
  attr_reader :id, :label

  def initialize(id:, label:)
    @id = id
    @label = label
  end

  def other?
    @id == :other
  end

  def self.other
    @other ||= new(id: :other, label: "other…")
  end

  def display_line(show_id: false)
    if show_id && !other?
      "#{@label}  —  #{@id}"
    else
      @label.to_s
    end
  end
end
