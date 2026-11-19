# frozen_string_literal: true

require "test_helper"

# SIDE DOORS TO A DELETED POST (2026-11-19 audit).
#
# A deleted post is hidden below deleted_post_visibility_level (ADMIN in
# production), and a jailed post is a deleted post carrying troll_jail: one
# rule, Post#hidden_from? and Post.hidden_from, decides both (operator
# 2026-10-10: "Jailed means deleted. Why do we need to program in 14,000 ways
# to NOT see 'deleted' posts?"). This file asks each door that named a post
# some other way than belongs_to :post whether a deleted post's id answers
# differently from a missing one, for a signed-out visitor, a member and a
# moderator, with an admin -- who sees deleted posts -- as the control.
#
# The doors: mod actions whose subject is a vote, comment, media asset or
# report on the post, or a favorites move onto it; the moderator dashboard;
# moderation reports; reactions; media metadata; a visible relative's
# parent_id, children flags, relatives strip and parent:/child: metatags; post
# versions' parent; nested parent searches; pool and favorite group counts;
# the posts sitemap index. And, as controls, the doors read as closed: media
# assets by md5, AI tags, comment votes, the random trail.
class DeletedPostSideDoorsTest < ActionDispatch::IntegrationTest
  MISSING = 999_999

  def answer(path, user, params = {})
    user ? get_auth(path, user, params: params, as: :json) : get(path, params: params, as: :json)
    [response.status, (response.status == 200) ? response.parsed_body : nil]
  end

  def ids(path, user, params = {})
    status, body = answer(path, user, params)
    assert_equal 200, status, "#{path} #{params.inspect} as #{user&.name || "anonymous"}"
    body.pluck("id")
  end

  def html(path, user, params = {})
    user ? get_auth(path, user, params: params) : get(path, params: params)
    response.body
  end

  # A post id in a body, not a longer one that starts with it.
  def names_post?(body, id)
    body.match?(%r{posts/#{id}(?!\d)|post ##{id}(?!\d)|parent(:|%3A)#{id}(?!\d)})
  end

  setup do
    Danbooru.config.stubs(:deleted_post_visibility_level).returns(User::Levels::ADMIN)
    @member = create(:user)
    @moderator = create(:moderator_user)
    @admin = create(:admin_user)
  end

  def hidden_viewers
    { "anonymous" => nil, "member" => @member, "moderator" => @moderator }
  end

  def signed_in_hidden_viewers
    { "member" => @member, "moderator" => @moderator }
  end

  # A post whose media asset is its own (the factory gives each a random md5).
  def post_with_asset(**attrs)
    md5 = SecureRandom.hex(16)
    as(@admin) { create(:post, md5: md5, media_asset: create(:media_asset, md5: md5), **attrs) }
  end

  context "Records about a deleted post" do
    setup do
      @deleted = post_with_asset(tag_string: "landscape")
      @visible = post_with_asset(tag_string: "landscape")
      @comment = as(@member) { create(:comment, post: @deleted, creator: @member, body: "deleted_comment") }
      @open_comment = as(@member) { create(:comment, post: @visible, creator: @member, body: "open_comment") }
      @vote = create(:post_vote, post: @deleted, score: 1)
      @comment_vote = create(:comment_vote, comment: @comment, score: 1)
      @report = as(@member) { create(:moderation_report, model: @comment, creator: @member) }
      @open_report = as(@member) { create(:moderation_report, model: @open_comment, creator: @member) }
      @ai_tag = create(:ai_tag, media_asset: @deleted.media_asset)
      # Three downvotes each, so both comments reach the dashboard's list.
      [@comment, @open_comment].each do |c|
        3.times { build(:comment_vote, comment: c, score: -1).save!(validate: false) }
        c.update_columns(score: -3)
      end
      @deleted.delete!("ordinary deletion", user: @admin)
      @deleted.reload

      @actions = [
        ModAction.log("deleted post vote ##{@vote.id} on post ##{@deleted.id}", :post_vote_delete, subject: @vote, user: @admin),
        ModAction.log("deleted comment ##{@comment.id}", :comment_delete, subject: @comment, user: @admin),
        ModAction.log("deleted comment vote ##{@comment_vote.id} on comment ##{@comment.id}", :comment_vote_delete, subject: @comment_vote, user: @admin),
        ModAction.log("deleted media asset ##{@deleted.media_asset.id} (md5=#{@deleted.md5})", :media_asset_delete, subject: @deleted.media_asset, user: @admin),
        ModAction.log("handled modreport ##{@report.id}", :moderation_report_handled, subject: @report, user: @admin),
      ]
      @open_action = ModAction.log("deleted comment ##{@open_comment.id}", :comment_delete, subject: @open_comment, user: @admin)
    end

    should "not list a mod action whose subject belongs to the deleted post" do
      signed_in_hidden_viewers.each do |who, user|
        listed = ids(mod_actions_path, user, limit: 200)
        visible_to_viewer = ModAction.visible(user).where(id: @actions.map(&:id)).pluck(:id)
        assert_not_empty visible_to_viewer, "fixture: some of these categories are #{who}'s to read"
        assert_empty listed & @actions.map(&:id), who
        assert_includes listed, @open_action.id, "control: a comment on a visible post, #{who}"

        @actions.each do |action|
          status, = answer(mod_action_path(action), user)
          assert_equal answer(mod_action_path(MISSING), user).first, status, "mod action #{action.category}, #{who}" if visible_to_viewer.include?(action.id)
        end
      end

      assert_equal @actions.map(&:id).sort, ids(mod_actions_path, @admin, limit: 200).intersection(@actions.map(&:id)).sort, "control: an admin sees deleted posts"
    end

    should "not show the deleted post's mod actions on the moderator dashboard" do
      get_auth "/moderator/dashboard", @moderator
      assert_response :success
      assert_not names_post?(response.body, @deleted.id), "the dashboard names the deleted post"
      assert_no_match(/#{@deleted.md5}/, response.body)

      get_auth "/moderator/dashboard", @admin
      assert_response :success
      assert_match(/#{@deleted.md5}/, response.body, "control: an admin's dashboard")
    end

    should "not show the deleted post's downvoted comment on the moderator dashboard" do
      get_auth "/moderator/dashboard", @moderator
      assert_response :success
      assert_no_match(/deleted_comment/, response.body, "the dashboard shows the deleted post's comment")
      assert_match(/open_comment/, response.body, "control: a comment on a visible post")

      get_auth "/moderator/dashboard", @admin
      assert_response :success
      assert_match(/deleted_comment/, response.body, "control: an admin's dashboard")
    end

    should "not list a moderation report on the deleted post's comment" do
      [false, true].each do |only_model|
        params = only_model ? { only: "id,model" } : {}
        listed = ids(moderation_reports_path, @moderator, params)
        assert_not_includes listed, @report.id, "only=model: #{only_model}"
        assert_includes listed, @open_report.id, "control: a report on a visible post's comment"
      end
      assert_equal answer(moderation_report_path(MISSING), @moderator).first, answer(moderation_report_path(@report), @moderator).first, "show"
      assert_includes ids(moderation_reports_path, @admin), @report.id, "control: an admin"
    end

    should "not list a reaction to the deleted post or its comment" do
      reactions = [@deleted, @comment, @visible].map do |model|
        reaction = Reaction.new(model: model, creator: @member, reaction_id: 1)
        reaction.save!(validate: false)
        reaction
      end
      hidden, open = reactions.first(2), reactions.last
      signed_in_hidden_viewers.each do |who, user|
        listed = ids(reactions_path, user)
        assert_empty listed & hidden.map(&:id), who
        assert_includes listed, open.id, "control: a visible post's reaction, #{who}"
        hidden.each do |reaction|
          assert_equal answer(reaction_path(MISSING), user).first, answer(reaction_path(reaction), user).first, "show #{reaction.model_type}, #{who}"
        end
      end
      assert_equal hidden.map(&:id).sort, ids(reactions_path, @admin).intersection(hidden.map(&:id)).sort, "control: an admin"
    end

    should "not list the deleted post's media metadata" do
      signed_in_hidden_viewers.each do |who, user|
        listed = ids(media_metadata_path, user, limit: 200)
        assert_not_includes listed, @deleted.media_asset.media_metadata.id, who
        assert_includes listed, @visible.media_asset.media_metadata.id, "control: a visible post's metadata, #{who}"
      end
      assert_includes ids(media_metadata_path, @admin, limit: 200), @deleted.media_asset.media_metadata.id, "control: an admin"
    end

    # Read as closed before this audit; asked so that stays shown.
    should "answer the media asset, AI tag and comment vote doors as for a missing post" do
      signed_in_hidden_viewers.each do |who, user|
        assert_empty ids(media_assets_path, user, search: { md5: @deleted.md5 }), "media assets by md5, #{who}"
        assert_not_empty ids(media_assets_path, user, search: { md5: @visible.md5 }), "control: media assets, #{who}"
        assert_empty ids(ai_tags_path, user, search: { media_asset_id: @deleted.media_asset.id }).compact, "ai tags, #{who}"
        assert_empty ids(comment_votes_path, user, search: { comment_id: @comment.id }), "comment votes, #{who}"
      end
    end
  end

  context "A favorites move from a child that was later undeleted" do
    should "not name the parent once the parent is deleted" do
      parent = as(@admin) { create(:post, tag_string: "landscape") }
      child = as(@admin) { create(:post, tag_string: "landscape", parent: parent) }
      create(:favorite, post: child, user: create(:user))
      as(@admin) { child.reload.delete!("duplicate", move_favorites: true, user: @admin) }
      child.update_columns(is_deleted: false) # rubocop:disable Rails/SkipsModelValidations -- restored, as an approval restores it
      parent.reload.delete!("ordinary deletion", user: @admin)

      signed_in_hidden_viewers.each do |who, user|
        _, rows = answer(mod_actions_path, user, search: { category: "post_move_favorites" })
        assert_not rows.any? { |row| names_post?(row["description"], parent.id) }, "#{who}: #{rows.pluck("description").inspect}"
      end
      get_auth "/moderator/dashboard", @moderator
      assert_not names_post?(response.body, parent.id), "the moderator dashboard"

      _, rows = answer(mod_actions_path, @admin, search: { category: "post_move_favorites" })
      assert_includes rows.pluck("description"), "moved favorites from post ##{child.id} to post ##{parent.id}", "control: an admin"
    end
  end

  context "A visible post beside a deleted relative" do
    setup do
      @first_version = PostVersion.maximum(:id).to_i
      as(@admin) do
        @parent = create(:post, tag_string: "landscape")
        @child = create(:post, tag_string: "landscape", parent: @parent)
        @lonely = create(:post, tag_string: "landscape")
        @deleted_child = create(:post, tag_string: "landscape", parent: @lonely)
        @open_parent = create(:post, tag_string: "landscape")
        @open_child = create(:post, tag_string: "landscape", parent: @open_parent)
      end
      @comment = as(@member) { create(:comment, post: @child, creator: @member, body: "child_comment") }
      @lonely_comment = as(@member) { create(:comment, post: @lonely, creator: @member, body: "lonely_comment") }
      @open_comment = as(@member) { create(:comment, post: @open_child, creator: @member, body: "open_comment") }
      as(@member) { create(:note, post: @child, body: "child_note") }
      @parent.reload.delete!("ordinary deletion", user: @admin)
      @deleted_child.reload.delete!("ordinary deletion", user: @admin)
      assert @child.reload.parent_id == @parent.id && !@child.is_deleted?, "fixture: a visible child naming its deleted parent"
      assert @lonely.reload.has_children?, "fixture: the stored flag counts the deleted child"
    end

    should "not name the deleted parent or child in a post's JSON or page" do
      hidden_viewers.each do |who, user|
        _, child = answer(post_path(@child), user)
        assert_nil child["parent_id"], who
        _, lonely = answer(post_path(@lonely), user)
        assert_equal false, lonely["has_children"], who
        assert_not names_post?(html(post_path(@child), user), @parent.id), "child page, #{who}"
        assert_not names_post?(html(post_path(@lonely), user), @deleted_child.id), "parent page, #{who}"
      end

      _, child = answer(post_path(@child), @admin)
      assert_equal @parent.id, child["parent_id"], "control: an admin"
      _, child = answer(post_path(@open_child), @member)
      assert_equal @open_parent.id, child["parent_id"], "control: a visible parent"
    end

    should "answer parent: and child: metatags as for a missing relative" do
      hidden_viewers.each do |who, user|
        find = ->(tags) { ids(posts_path, user, tags: "#{tags} id:#{@child.id},#{@lonely.id},#{@open_child.id},#{@open_parent.id}") }
        assert_equal find.call("parent:#{MISSING}"), find.call("parent:#{@parent.id}"), "parent:id, #{who}"
        assert_not_includes find.call("parent:any"), @child.id, "parent:any, #{who}"
        assert_includes find.call("parent:none"), @child.id, "parent:none, #{who}"
        assert_not_includes find.call("parent:deleted"), @child.id, "parent:deleted, #{who}"
        assert_not_includes find.call("child:any"), @lonely.id, "child:any, #{who}"
        assert_includes find.call("child:none"), @lonely.id, "child:none, #{who}"
        assert_not_includes find.call("child:deleted"), @lonely.id, "child:deleted, #{who}"
        assert_includes find.call("parent:any"), @open_child.id, "control: parent:any, #{who}"
        assert_includes find.call("child:any"), @open_parent.id, "control: child:any, #{who}"
      end
      assert_includes ids(posts_path, @admin, tags: "parent:any id:#{@child.id}"), @child.id, "control: an admin"
    end

    should "not name the deleted parent in the child's post versions" do
      hidden_viewers.each do |who, user|
        _, rows = answer(post_versions_path, user, search: { post_id: @child.id })
        next if rows.nil? # signed out: history is for members

        rows = rows.select { |row| row["id"] > @first_version }
        assert_not_empty rows, "fixture: the child has versions (#{who})"
        assert_equal [nil], rows.pluck("parent_id").uniq, who

        own = ->(search) { ids(post_versions_path, user, { search: search.merge(post_id: @child.id) }) }
        assert_equal own.call(parent_id: MISSING), own.call(parent_id: @parent.id), "search[parent_id], #{who}"
        assert_equal own.call(parent_id: "#{MISSING}..#{MISSING}"), own.call(parent_id: "#{@parent.id}..#{@parent.id}"), "a range, #{who}"
        assert_equal own.call(parent_id_not: MISSING), own.call(parent_id_not: @parent.id), "search[parent_id_not], #{who}"

        assert_not names_post?(html(post_versions_path, user, search: { post_id: @child.id }), @parent.id), "history page, #{who}"
      end

      _, rows = answer(post_versions_path, @member, search: { post_id: @open_child.id })
      assert_includes rows.pluck("parent_id"), @open_parent.id, "control: a visible parent is still named"
      assert_not_empty ids(post_versions_path, @member, search: { post_id: @open_child.id, parent_id: @open_parent.id }), "control: and still found"
      _, rows = answer(post_versions_path, @admin, search: { post_id: @child.id })
      assert_includes rows.pluck("parent_id"), @parent.id, "control: an admin"
    end

    should "answer a nested search by the deleted parent exactly as by a missing one" do
      hidden_viewers.each do |who, user|
        [
          [comments_path, { post: { parent_id: @parent.id }}, { post: { parent_id: MISSING }}],
          [comments_path, { post: { parent_id: "#{@parent.id}..#{@parent.id}" }}, { post: { parent_id: "#{MISSING}..#{MISSING}" }}],
          [comments_path, { post_id: @child.id, post: { parent_id_not: @parent.id }}, { post_id: @child.id, post: { parent_id_not: MISSING }}],
          [comments_path, { post_id: @child.id, post: { has_parent: true }}, { post_id: @lonely.id, post: { has_parent: true }}],
          [users_path, { posts: { parent_id: @parent.id }}, { posts: { parent_id: MISSING }}],
          [notes_path, { post: { parent_id: @parent.id }}, { post: { parent_id: MISSING }}],
          [comments_path, { post: { parent: { id: @parent.id }}}, { post: { parent: { id: MISSING }}}],
        ].each do |path, hit, miss|
          assert_equal answer(path, user, search: miss), answer(path, user, search: hit), "#{path} #{hit.inspect}, #{who}"
        end
        next if user.nil? # comments are for members; the equalities above still held

        assert_empty ids(comments_path, user, search: { post_id: @lonely.id, post: { has_children: true }}), "has_children, #{who}"
        assert_equal [@lonely_comment.id], ids(comments_path, user, search: { post_id: @lonely.id, post: { has_children: "false" }}), "has_children=false, #{who}"
        assert_equal [@comment.id], ids(comments_path, user, search: { post_id: @child.id, post: { has_parent: "false" }}), "has_parent=false, #{who}"
      end

      assert_equal [@open_comment.id], ids(comments_path, @member, search: { post: { parent_id: @open_parent.id }}), "control: a visible parent"
      assert_equal [@open_comment.id], ids(comments_path, @member, search: { post_id: @open_child.id, post: { has_parent: true }}), "control: has_parent"
      assert_equal [@comment.id], ids(comments_path, @admin, search: { post: { parent_id: @parent.id }}), "control: an admin"
    end
  end

  context "The posts sitemap index" do
    should "list no block that only a deleted newest post fills" do
      limit = User.anonymous.listing_per_page_limit
      visible = as(@admin) { create(:post, tag_string: "landscape") }
      Post.connection.execute("SELECT setval('posts_id_seq', #{((visible.id / limit) + 3) * limit})")
      newest = as(@admin) { create(:post, tag_string: "landscape") }
      newest.delete!("ordinary deletion", user: @admin)

      get sitemap_path(sitemap: "posts"), as: :xml
      assert_response :success
      ranges = response.parsed_body.css("sitemap loc").map do |loc|
        tags = Rack::Utils.parse_query(URI.parse(loc.text).query)["tags"]
        lo, hi = tags[/id:(\d+\.\.\d+)/, 1].split("..").map(&:to_i)
        lo..hi
      end
      assert ranges.any? { |range| range.cover?(visible.id) }, "control: the visible post #{visible.id} has its block"
      assert_not ranges.any? { |range| range.cover?(newest.id) }, "the deleted newest post #{newest.id} has a block"
    end
  end

  context "A pool and a favorite group holding deleted posts" do
    setup do
      @visible = as(@admin) { create(:post, tag_string: "landscape") }
      @other = as(@admin) { create(:post, tag_string: "landscape") }
      @deleted = as(@admin) { create(:post, tag_string: "landscape") }
      @deleted2 = as(@admin) { create(:post, tag_string: "landscape") }
      @pool = as(@admin) { create(:pool) }
      @pool.update_columns(post_ids: [@visible.id, @deleted.id, @deleted2.id]) # rubocop:disable Rails/SkipsModelValidations -- added before the deletion
      @small = as(@admin) { create(:pool) }
      @small.update_columns(post_ids: [@visible.id, @other.id]) # rubocop:disable Rails/SkipsModelValidations -- the comparison pool
      @group = create(:favorite_group, creator: @member)
      @group.update_columns(post_ids: [@visible.id, @deleted.id]) # rubocop:disable Rails/SkipsModelValidations -- added before the deletion
      @deleted.delete!("ordinary deletion", user: @admin)
      @deleted2.delete!("ordinary deletion", user: @admin)
    end

    should "count only the posts the searcher may see" do
      signed_in_hidden_viewers.each do |who, user|
        stored = answer(pools_path, user, search: { id: @pool.id, post_id_count: 3 })
        shown = answer(pools_path, user, search: { id: @pool.id, post_id_count: 1 })
        assert_equal shown, stored, "pools, #{who}"
        assert_not_equal 200, stored.first, "refused, naming the alternative (#{who})"
        assert_match(/post_ids_include_any|post_count/, response.body, who)

        assert_equal answer(favorite_groups_path, user, search: { id: @group.id, post_id_count: 1 }), answer(favorite_groups_path, user, search: { id: @group.id, post_id_count: 2 }), "favorite groups, #{who}"
        assert_equal answer(pool_versions_path, user, search: { post_id_count: 1 }).first, answer(pool_versions_path, user, search: { post_id_count: 3 }).first, "pool versions, #{who}"

        assert_equal [@small.id, @pool.id], ids(pools_path, user, search: { id: "#{@pool.id},#{@small.id}", order: "post_count" }), "order=post_count, #{who}"
      end
      assert_equal [@pool.id, @small.id], ids(pools_path, @admin, search: { id: "#{@pool.id},#{@small.id}", order: "post_count" }), "control: an admin counts deleted posts"
      assert_equal [@pool.id], ids(pools_path, @member, search: { id: @pool.id, post_ids_include_any: @visible.id }), "control: a pool is still found by a visible post"
    end
  end

  # Read as closed: the trail is stored ids, but every candidate passes
  # PostSurface#flank_shown?. Asked so that stays shown.
  context "A random trail holding a post deleted since" do
    should "not offer the deleted post as a neighbour" do
      here, gone, after = as(@admin) { Array.new(3) { create(:post, tag_string: "landscape") } }
      ModulationSetting.find_or_initialize_by(user_id: @member.id).update!(random_trails: { "" => { "ids" => [gone.id, here.id, after.id], "t" => Time.now.to_i } })
      gone.delete!("ordinary deletion", user: @admin)

      preset = PostSurface.new(post: here, viewer: @member, query: "order:random").nav_presets.find { |p| p[:key] == "random" }
      offered = (preset[:prev_candidates] + preset[:next_candidates]).pluck(:id)
      assert_not_includes offered, gone.id
      assert_includes offered, after.id, "control: the visible neighbour on the trail"
    end
  end
end
