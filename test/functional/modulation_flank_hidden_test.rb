# frozen_string_literal: true

require "test_helper"

# The post view's side strip -- the neighbour thumbnails either side of the
# centre. It asked only Post#visible?, so an admin who can see deleted posts
# was handed a jailed neighbour's thumbnail sharp, beside a centre that blurs
# the same post (operator, 2026-10-07: "the thumbs were still visible in
# either direction").
class ModulationFlankHiddenTest < ActionDispatch::IntegrationTest
  JAIL = "troll_jail"

  def flank_previews(post, user)
    get_auth post_modulation_path(post, format: :json), user
    assert_response :success
    response.parsed_body.fetch("presets", []).flat_map { |p| [p["prev"], p["next"]] }.compact
  end

  context "a jailed neighbour" do
    setup do
      Danbooru.config.stubs(:deleted_post_visibility_level).returns(User::Levels::ADMIN)
      Danbooru.config.stubs(:banished_posts_need_reveal?).returns(true)
      @bot = create(:builder_user)
      @admin = create(:admin_user)
      as(@bot) do
        @before = create(:post, tag_string: "landscape", uploader: @bot)
        @jailed = create(:post, tag_string: "landscape #{JAIL}", uploader: @bot)
        @after = create(:post, tag_string: "landscape", uploader: @bot)
      end
      @jailed.delete!("troll jail: shock", user: @admin)
    end

    should "never hand an admin with reveal off its thumbnail" do
      flank_previews(@after, @admin).select { |n| n["id"] == @jailed.id }.each do |n|
        assert_nil n["thumb"], "reveal off: the jailed neighbour's thumbnail was handed out"
      end
    end

    should "flag it deleted for an admin with reveal on, so the strip blurs it" do
      ModulationSetting.record!(@admin, nil, { "reveal_banished" => "true" })
      jailed = flank_previews(@after, @admin).select { |n| n["id"] == @jailed.id }
      assert jailed.any?, "fixture: with reveal on, the jailed post is a neighbour"
      jailed.each { |n| assert_equal true, n["deleted"] }
    end
  end
end
