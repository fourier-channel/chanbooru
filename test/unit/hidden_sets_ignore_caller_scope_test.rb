# frozen_string_literal: true

require "test_helper"

# The hidden sets are request-wide answers, memoized per viewer. A class
# method called on a relation runs in that relation's scope, so a set first
# asked for inside Post.where(...) was computed from that relation's posts
# alone, and the narrowed answer was then served to every query after it in
# the request (review 2026-11-20). CreatorVisibility.memoized computes them
# outside the caller's scope.
class HiddenSetsIgnoreCallerScopeTest < ActiveSupport::TestCase
  context "A flagged tag on two posts" do
    setup do
      @admin = create(:admin_user)
      @member = create(:user)
      @a = as(@admin) { create(:post, tag_string: "scope_secret_r1 a") }
      @b = as(@admin) { create(:post, tag_string: "scope_secret_r1 b") }
      @other = as(@admin) { create(:post, tag_string: "a") }
      TagQuarantine.flag!(Tag.find_by!(name: "scope_secret_r1"), by: @admin)
    end

    should "be hidden whole when first asked for inside a relation naming one of them" do
      inside = Post.where(id: @a.id).scoping { TagQuarantine.hidden_post_ids_for(@member) }
      after = TagQuarantine.hidden_post_ids_for(@member)

      assert_equal [@a.id, @b.id], inside
      assert_equal [@a.id, @b.id], after, "the memo keeps the whole set"
    end

    should "not be emptied when first asked for inside a relation naming neither" do
      inside = Post.where(id: @other.id).scoping { TagQuarantine.hidden_post_ids_for(@member) }

      assert_equal [@a.id, @b.id], inside
      assert_equal [@a.id, @b.id], TagQuarantine.hidden_post_ids_for(@member)
    end
  end
end
