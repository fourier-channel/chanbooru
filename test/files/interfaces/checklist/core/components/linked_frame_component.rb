# frozen_string_literal: true

# LinkedCardComponent named in a comment is not a link; rendering it is.
class LinkedFrameComponent < ApplicationComponent
  def call
    render LinkedCardComponent.new
  end
end
