# frozen_string_literal: true

# Serves the error cards at /errors/<status>.svg.
#
# These exist because a failed image is otherwise a broken-image icon and, in
# some browsers, the raw filename -- which tells a visitor nothing about whether
# they lack permission, browsed too fast, or found a genuine hole. The card says
# which, in words.
#
# Public and immutable: the card for a given status never changes, so it is
# cached hard. That matters because these are requested exactly when something
# is already going wrong, and the failure path should not also be the expensive
# path.
class ErrorsController < ApplicationController
  respond_to :svg

  # SVG has no text wrapping.
  WRAP_COLUMNS = 62

  def show
    skip_authorization

    @art = ErrorArt.new(params[:status])
    @lines = wrap(@art.body)
    # Only the caller knows how big the box is, so the caller picks the layout.
    @compact = params[:compact].present?

    expires_in 1.year, public: true
    render formats: [:svg], layout: false
  end

  private

  def wrap(text, columns: WRAP_COLUMNS)
    text.to_s.split.each_with_object([""]) do |word, lines|
      if lines.last.empty?
        lines[-1] = word
      elsif lines.last.length + 1 + word.length <= columns
        lines[-1] = "#{lines.last} #{word}"
      else
        lines << word
      end
    end
  end
end
