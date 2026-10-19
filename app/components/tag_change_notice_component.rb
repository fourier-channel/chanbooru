# frozen_string_literal: true

class TagChangeNoticeComponent < ApplicationComponent
  extend Memoist

  attr_reader :tag, :current_user

  def initialize(tag:, current_user:)
    super
    @tag = tag
    @current_user = current_user
  end

  memoize def pending_burs
    return BulkUpdateRequest.none unless tag.present?
    BulkUpdateRequest.pending.where_array_includes_any(:tags, tag.name)
  end

  def render?
    !@current_user.is_anonymous? && @tag.present?
  end
end
