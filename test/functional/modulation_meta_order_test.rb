# frozen_string_literal: true

require "test_helper"

# THE HEADER IS ONE LINE (operator, 2026-10-18: nothing above the stage may
# move between posts), so fields past its width are scrolled to, not wrapped
# onto a second line that one post needs and the next does not. What says the
# post's state therefore comes first, where it is never the part cut off: the
# status (when it is not active), the rating, the source; the file's numbers
# and the uploader after them (review, 2026-10-18: at phone width the source,
# the rating and the status were the fields off the edge on every post).
class ModulationMetaOrderTest < ActionDispatch::IntegrationTest
  setup do
    @uploader = create(:user)
  end

  def meta(post)
    as(@uploader) { ModulationPostComponent.new(post: post, viewer: @uploader).payload[:meta] }.pluck(:text)
  end

  should "put the status, the rating and the source before the file's numbers and the uploader" do
    post = as(@uploader) { create(:post, rating: "s", source: "https://example.com/a.jpg", is_deleted: true, image_width: 640, image_height: 480) }

    assert_equal ["deleted", "rating:s", "source", "640\u00d7480"], meta(post).first(4)
    assert_equal "@#{post.uploader.name}", meta(post).last
  end

  should "start with the rating on an active post with no source" do
    post = as(@uploader) { create(:post, rating: "g", source: "") }

    assert_equal "rating:g", meta(post).first
    assert_not_includes meta(post), "source"
  end
end
