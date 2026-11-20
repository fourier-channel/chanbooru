# frozen_string_literal: true

require "test_helper"

# boo.122 E1 (2026-11-20): the creator's panel found its post with a plain
# Post.find_by and read its per-post rows unfiltered, so for a post JAILED
# after the creator set it -- a post that exists for nobody but the
# pipeline, its creator and admins included -- the panel opened it in the
# one-post editor, listed it under posts set differently and people let in
# (by id and link), counted it in a group's "used by: N posts", and wrote
# audiences and rules on it. The timed-link door already asked hidden_from?.
#
# Now the panel asks the post's own question (Post#hidden_from? of the
# viewer, Post.hidden_from as SQL): a hidden post is answered as a missing
# one, and its old rows are counted with the stale ones, never named.
class CreatorPanelHiddenPostTest < ActionDispatch::IntegrationTest
  MAPLE = { "X-Fourier-Identity" => "@maple:41chan.net" }.freeze

  def maple_post(tags = "landscape")
    post = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: tags) }
    FourierPostCreator.create!(post: post, mxid: "@maple:41chan.net", recorded_by: @tunnel.id)
    post
  end

  def panel(user, act, headers: MAPLE, **params)
    put_auth creator_gallery_path(@gallery), user, params: { panel: act, **params }, headers: headers
  end

  def state
    [
      CreatorUserRule.order(:id).pluck(:user_id, :post_id, :rule),
      CreatorPostAudience.order(:id).pluck(:post_id, :creator_gallery_id, :audience),
      CreatorAudienceGroup.order(:id).pluck(:creator_group_id, :post_id),
    ]
  end

  # As the jail does it: the jail account tags the post, then deletes it.
  def jail!(post)
    as(@sample) { post.update!(tag_string: "#{post.tag_string} troll_jail") }
    post.reload.delete!("troll jail: shock", user: @sample)
    post.reload
  end

  setup do
    Danbooru.config.stubs(:deleted_post_visibility_level).returns(User::Levels::ADMIN)
    Danbooru.config.stubs(:banished_posts_withheld?).returns(true)
    CreatorPrefixes.reset!

    @tunnel = create(:contributor_user, name: "tunnel") # posts several fixtures: no upload limit
    @sample = create(:approver_user, name: "sample")
    @admin = create(:admin_user)
    @maple = create(:user)
    @ruled = create(:user)
    @stranger = create(:user)
    @gallery = CreatorGallery.create!(slug: "maple", matrix_id: "@maple:41chan.net", title: "Maple", user: @maple)
    @tier = CreatorGroup.make!(@gallery, name: "41chan_maple_tier_1", tier: 1, by: @maple, open_to_requests: true)

    # Set while visible, then jailed: what the panel held before the jailing.
    @jailed = maple_post("landscape")
    panel(@maple, "post_audience", post_id: @jailed.id, audience: "groups", group_ids: [@tier.id])
    panel(@maple, "set_rule", post_id: @jailed.id, user_name: @ruled.name, rule: "allow")
    assert CreatorPostAudience.exists?(post: @jailed), "fixture: the audience was set"
    assert CreatorUserRule.exists?(post: @jailed, user: @ruled), "fixture: the rule was set"
    get_auth edit_creator_gallery_path(@gallery), @maple, headers: MAPLE # spends the notice the writes left
    jail!(@jailed)

    assert @jailed.jailed?, "fixture: jailed"
    [@maple, @admin].each { |user| assert @jailed.hidden_from?(user), "fixture: hidden from #{user.level_string}" }
  end

  should "name it nowhere in the panel, to its creator or an admin" do
    # An admin opens any gallery's panel by booru session alone (creator_panel_test).
    [[@maple, MAPLE], [@admin, {}]].each do |user, headers|
      get_auth edit_creator_gallery_path(@gallery, view: "identity", post_id: 999_999), user, headers: headers
      assert_response :success
      missing_page = response.body
      get_auth edit_creator_gallery_path(@gallery, view: "identity", post_id: @jailed.id), user, headers: headers
      assert_response :success
      page = response.body

      assert_includes missing_page, "Post #999999 is not one of your posts", user.name
      assert_includes page, "Post ##{@jailed.id} is not one of your posts", "#{user.name}: the editor"
      assert_not_includes page, "<h4>Post ##{@jailed.id}</h4>", "#{user.name}: the editor"
      assert_not_includes page, "href=\"#{post_path(@jailed)}\"", "#{user.name}: posts set differently"
      assert_not_includes page, "post ##{@jailed.id} only", "#{user.name}: people let in"
      assert_no_match(/used by: (your default, )?1 post\b/, page, "#{user.name}: the group's use")
      # Its rule and its audience, each counted in its own section.
      assert_equal 2, page.scan("1 older setting no longer applies: its post is no longer yours or no longer exists for you.").size, "#{user.name}: counted as stale"
    end
  end

  should "refuse every write on it in a missing post's words" do
    before = state
    [["post_audience", { audience: "public" }], ["set_rule", { user_name: @stranger.name, rule: "block" }]].each do |act, params|
      panel(@maple, act, post_id: 999_999, **params)
      missing = flash[:notice]
      panel(@maple, act, post_id: @jailed.id, **params)

      assert_match(/is not one of your posts/, missing, act)
      assert_equal missing.sub("999999", @jailed.id.to_s), flash[:notice], act
    end

    panel(@maple, "clear_rule", post_id: 999_999, user_id: @ruled.id)
    missing = flash[:notice]
    panel(@maple, "clear_rule", post_id: @jailed.id, user_id: @ruled.id)
    assert_match(/no such setting/, missing)
    assert_equal missing, flash[:notice], "clear_rule"
    assert_equal before, state
  end

  should "still show and count a visible post set the same way" do
    live = maple_post("landscape")
    panel(@maple, "post_audience", post_id: live.id, audience: "groups", group_ids: [@tier.id])
    panel(@maple, "set_rule", post_id: live.id, user_name: @ruled.name, rule: "allow")

    get_auth edit_creator_gallery_path(@gallery, view: "identity", post_id: live.id), @maple, headers: MAPLE
    assert_response :success
    assert_includes response.body, "<h4>Post ##{live.id}</h4>"
    assert_includes response.body, "href=\"#{post_path(live)}\""
    assert_includes response.body, "post ##{live.id} only"
    assert_match(/used by: (your default, )?1 post\b/, response.body)
  end
end
