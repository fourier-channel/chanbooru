# frozen_string_literal: true

require "test_helper"

# The post view's side strip -- the neighbour thumbnails either side of the
# centre. It asked only Post#visible?, so an admin who can see deleted posts
# was handed a jailed neighbour's thumbnail sharp, beside a centre that blurs
# the same post (operator, 2026-10-07: "the thumbs were still visible in
# either direction").
class ModulationFlankHiddenTest < ActionDispatch::IntegrationTest
  JAIL = "troll_jail"

  # Every flank candidate in the payload, each with its entry in the
  # candidates map merged in (thumb, deleted).
  def flank_previews(post, user)
    get_auth post_modulation_path(post, format: :json), user
    assert_response :success
    body = response.parsed_body
    refs = body.fetch("presets", []).flat_map { |p| p.fetch("prev_candidates") + p.fetch("next_candidates") }
    refs.map { |ref| ref.merge(body.fetch("candidates").fetch(ref["id"].to_s)) }
  end

  context "a jailed neighbour" do
    setup do
      Danbooru.config.stubs(:deleted_post_visibility_level).returns(User::Levels::ADMIN)
      Danbooru.config.stubs(:banished_posts_withheld?).returns(true)
      @bot = create(:builder_user)
      @admin = create(:admin_user)
      as(@bot) do
        @before = create(:post, tag_string: "landscape", uploader: @bot)
        @jailed = create(:post, tag_string: "landscape #{JAIL}", uploader: @bot)
        @after = create(:post, tag_string: "landscape", uploader: @bot)
      end
      @jailed.delete!("troll jail: shock", user: @admin)
    end

    should "never hand an admin its thumbnail" do
      ids = flank_previews(@after, @admin).pluck("id")
      assert_not_includes ids, @jailed.id
      assert_includes ids, @before.id, "fixture: the flanks were built"
      assert_not_includes response.body, JAIL
    end

    # No reveal (2026-10-12): no admin is shown a jailed post, so it is no
    # neighbour of theirs at all; an ordinary deletion still is, blurred.
    should "not list it as a neighbour for an admin, and flag an ordinary deleted one" do
      assert flank_previews(@after, @admin).none? { |n| n["id"] == @jailed.id }

      @jailed.update_columns(tag_string: "landscape") # rubocop:disable Rails/SkipsModelValidations -- the jail tag off, past the hooks, leaving an ordinary deletion
      deleted = flank_previews(@after, @admin).select { |n| n["id"] == @jailed.id }
      assert deleted.any?, "fixture: an ordinary deleted post is a neighbour for an admin"
      deleted.each do |n|
        assert_equal true, n["deleted"]
        assert_predicate n["thumb"], :present?, "a deleted post the admin may see keeps its (blurred) thumbnail"
      end
    end
  end
end
