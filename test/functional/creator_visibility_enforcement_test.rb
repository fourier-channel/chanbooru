# frozen_string_literal: true

require "test_helper"

# CREATOR VISIBILITY, ENFORCED (design CREATOR_VISIBILITY sections 6, 7 and 9,
# ruled 2026-10-07; stage 3, 2026-10-08). What the creator's panel decides
# (CreatorVisibility) reaching every door a viewer would try:
#
#   NARROW -- a post the creator did not let this viewer see does not exist
#   for them, exactly as gate 1 means for a signed-out visitor: its page, its
#   JSON, the md5 lookup, search results, the count, the neighbours, the
#   preview strip and the media gate.
#   WIDEN -- an explicit allow lets a viewer below Gold past the level gate
#   (levelblocked?), and so to the md5 fourier-auth reads as "serve it";
#   never a signed-out viewer, a banned one, a jailed post, or past an
#   unreleased hidden prefix.
#   ALWAYS SEE -- the controller, the posting bots, admins; and every admin
#   page view of a post its creator hid is logged, admin-only (Q2).
class CreatorVisibilityEnforcementTest < ActionDispatch::IntegrationTest
  GATED = "child" # in Danbooru.config.restricted_tags (gated_posts_test asserts it)

  def maple_post(tags)
    post = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: tags) }
    FourierPostCreator.create!(post: post, mxid: "@maple:41chan.net", recorded_by: @tunnel.id)
    post
  end

  # As `user`, or signed out (a fresh session) when `user` is nil.
  def get_as(user, path, **params)
    if user
      get_auth(path, user, params: params)
    else
      reset!
      get(path, params: params)
    end
  end

  def status_for(post, user)
    get_as(user, post_path(post, format: :json))
    response.status
  end

  def ids_for(user, tags)
    get_as(user, posts_path(format: :json), tags: tags, limit: 100)
    assert_response :success
    response.parsed_body.pluck("id")
  end

  def count_for(user, tags)
    get_as(user, posts_counts_path(format: :json), tags: tags)
    assert_response :success
    response.parsed_body.dig("counts", "posts")
  end

  # The md5 as posts.json gives it: present only when PostPolicy#can_see_media?
  # -- which is what fourier-auth's booru door reads as permission to serve.
  def md5_for(post, user)
    get_auth posts_path(format: :json), user, params: { tags: "id:#{post.id}" }
    assert_response :success
    response.parsed_body.first&.fetch("md5", nil)
  end

  def name_of(user) = user&.name || "anonymous"

  # Class level: shoulda runs each `should` through instance_exec, so a `def`
  # inside a context is not on the object the block runs against.
  def views = ModAction.where(category: "creator_hidden_post_view")

  # Every query the code issues, as creator_visibility_test counts them.
  def queries_during(&)
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &)
    count
  end

  def body_for(path, user, **params)
    get_as(user, path, **params)
    assert_response :success
    response.body
  end

  setup do
    CreatorPrefixes.reset!
    CreatorTagRelease.reset_cache!
    @tunnel = create(:builder_user, name: "tunnel")
    @admin = create(:admin_user)
    @moderator = create(:moderator_user)
    @maple = create(:user)
    @fan = create(:user)
    @named = create(:user)
    @stranger = create(:user)
    @gallery = CreatorGallery.create!(matrix_id: "@maple:41chan.net", slug: "maple-cv", user: @maple)
    @tier = CreatorGroup.make!(@gallery, name: "41chan_maple_tier_1", tier: 1, by: @maple)
    @tier.add_member!(@fan, by: @maple)

    @plain = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "cvtest landscape") }
    @grouped = maple_post("cvtest landscape") # the creator default: groups-only, the tier
    @closed = maple_post("cvtest landscape")  # private, @named allowed by name
    @gated = maple_post("cvtest #{GATED}")    # public, the tier listed: widens
    @gallery.set_default_audience!("groups", by: @maple, group_ids: [@tier.id])
    CreatorPostAudience.set!(@closed, gallery: @gallery, audience: "private", by: @maple)
    CreatorUserRule.set!(@gallery, @named, rule: "allow", by: @maple, post: @closed)
    CreatorPostAudience.set!(@gated, gallery: @gallery, audience: "public", by: @maple, group_ids: [@tier.id])
    CreatorVisibility.forget!
  end

  teardown do
    CreatorPrefixes.reset!
  end

  context "narrowing" do
    should "answer a post's page and JSON only to whoever the creator let in" do
      expected = {
        nil => { @plain => 200, @grouped => 404, @closed => 404, @gated => 404 },
        @stranger => { @plain => 200, @grouped => 404, @closed => 404, @gated => 200 },
        @fan => { @plain => 200, @grouped => 200, @closed => 404, @gated => 200 },
        @named => { @plain => 200, @grouped => 404, @closed => 200, @gated => 200 },
        @moderator => { @plain => 200, @grouped => 404, @closed => 404, @gated => 200 },
        @maple => { @plain => 200, @grouped => 200, @closed => 200, @gated => 200 },
        @tunnel => { @plain => 200, @grouped => 200, @closed => 200, @gated => 200 },
        @admin => { @plain => 200, @grouped => 200, @closed => 200, @gated => 200 },
      }
      expected.each do |user, statuses|
        statuses.each { |post, status| assert_equal status, status_for(post, user), "post ##{post.id} for #{name_of(user)}" }
      end
    end

    should "leave it out of search results and the count, even searched for by id" do
      assert_equal [@gated.id, @plain.id].sort, ids_for(@stranger, "cvtest").sort
      assert_equal [@gated.id, @grouped.id, @plain.id].sort, ids_for(@fan, "cvtest").sort
      assert_equal [@closed.id, @gated.id, @plain.id].sort, ids_for(@named, "cvtest").sort
      assert_empty ids_for(@stranger, "id:#{@closed.id}")
      assert_equal 2, count_for(@stranger, "cvtest")
      assert_equal 3, count_for(@fan, "cvtest")
      assert_equal 0, count_for(@stranger, "id:#{@grouped.id}")
      assert_equal 4, count_for(@admin, "cvtest")
    end

    # One viewer's count is never served to another: the term is in the AST,
    # so it is in the count cache key.
    should "give two viewers who see different posts different count cache keys" do
      key = ->(user) { PostQuery.normalize("cvtest", current_user: user).with_implicit_metatags.count_cache_key }

      assert_not_equal key.call(@stranger), key.call(@fan)
      assert_includes key.call(@stranger), @grouped.id.to_s
    end

    # The hidden-post term is a long id list, rendered as one array literal
    # past Searchable::LONG_IN_LIST (2026-10-08). Asked both ways, since a
    # negated equality is the easy one to get wrong.
    should "match a long id list exactly, and its negation exactly" do
      missing = ((Post.maximum(:id) + 1)..).first(Searchable::LONG_IN_LIST + 1)
      ids = [@plain.id, @closed.id, *missing].join(",")
      assert_equal [@closed.id, @plain.id].sort, ids_for(@admin, "cvtest id:#{ids}").sort
      assert_equal [@gated.id, @grouped.id].sort, ids_for(@admin, "cvtest -id:#{ids}").sort
    end

    should "not confirm it by md5" do
      get_auth posts_path(format: :json), @stranger, params: { md5: @grouped.md5 }
      assert_response 404
      get_auth posts_path(format: :json), @fan, params: { md5: @grouped.md5 }
      assert_response :success
    end

    should "step over it between neighbours" do
      first = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "cvnb") }
      hidden = maple_post("cvnb")
      last = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "cvnb") }
      assert_operator first.id, :<, hidden.id
      assert_operator hidden.id, :<, last.id
      CreatorVisibility.forget!

      # id_desc: the next post from the newest is the one below it.
      assert_equal first.id, PostNeighbors.new(post: last, tags: "cvnb", user: @stranger).next_id
      assert_equal last.id, PostNeighbors.new(post: first, tags: "cvnb", user: @stranger).prev_id
      assert_equal hidden.id, PostNeighbors.new(post: last, tags: "cvnb", user: @fan).next_id
    end

    should "not draw it in a preview strip, nor serve its media" do
      assert_not PostPreviewComponent.new(post: @grouped, current_user: @stranger).render?
      assert PostPreviewComponent.new(post: @grouped, current_user: @fan).render?
      assert_not MediaAssetPolicy.new(@stranger, @grouped.media_asset).can_see_image?
      assert MediaAssetPolicy.new(@fan, @grouped.media_asset).can_see_image?
    end

    # So a re-upload by the posting bot is merged, never refused as
    # unpostable; anyone else it is hidden from is refused.
    should "never refuse the posting bot's re-upload" do
      assert_not @closed.refuses_duplicate_upload_from?(@tunnel)
      assert @closed.refuses_duplicate_upload_from?(@stranger)
    end
  end

  context "widening" do
    should "let a group member below Gold past the level gate, and serve them the media" do
      assert_not @gated.levelblocked?(@fan)
      assert @gated.levelblocked?(@stranger)
      assert_equal @gated.md5, md5_for(@gated, @fan)
      assert_nil md5_for(@gated, @stranger)
      assert MediaAssetPolicy.new(@fan, @gated.media_asset).can_see_image?
      assert_not MediaAssetPolicy.new(@stranger, @gated.media_asset).can_see_image?
    end

    # Every Matrix post is uploaded by the bridge account, so the creator gets
    # no uploader's unlock; being the controller is theirs instead.
    should "let the controller past the level gate on their own post" do
      assert_not @gated.levelblocked?(@maple)
      assert_equal @gated.md5, md5_for(@gated, @maple)
    end

    should "never reach a banned viewer" do
      create(:ban, user: @fan)
      assert @fan.reload.is_banned?
      CreatorVisibility.forget!

      assert @gated.levelblocked?(@fan)
      assert_nil md5_for(@gated, @fan)
    end

    # A jailing whose deletion half failed is held back by levelblocked?
    # alone (troll_jail is a restricted tag): "jailed -- never shown".
    should "never reach a jailed post" do
      jailed = maple_post("cvtest #{Danbooru.config.troll_jail_tag}")
      CreatorPostAudience.set!(jailed, gallery: @gallery, audience: "public", by: @maple, group_ids: [@tier.id])
      CreatorVisibility.forget!

      assert_not jailed.is_deleted?
      assert jailed.levelblocked?(@fan)
      assert jailed.levelblocked?(@maple)
    end

    should "not reach past the site's own gate for 'public' alone" do
      plain_gated = maple_post("cvtest #{GATED}")
      CreatorPostAudience.set!(plain_gated, gallery: @gallery, audience: "public", by: @maple)
      CreatorVisibility.forget!

      assert plain_gated.levelblocked?(@fan)
    end
  end

  # Section 7: an unreleased creator under a hidden prefix stays at the prefix
  # default, and nothing in the panel widens it; the RELEASE comes first.
  context "a creator under a hidden prefix" do
    setup do
      artist = as(@admin) { create(:artist, name: "aichan_maple") }
      ArtistClaim.create!(artist: artist, creator_gallery: @gallery).approve!(by: @admin)
      @ai = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "aichan_maple #{GATED}") }
      CreatorPostAudience.set!(@ai, gallery: @gallery, audience: "public", by: @maple, group_ids: [@tier.id])
      CreatorVisibility.forget!
    end

    should "stay hidden from the creator's group and widen nothing until released" do
      assert_equal 404, status_for(@ai, @fan)
      assert @ai.levelblocked?(@fan)
      assert_equal 200, status_for(@ai, @maple)
    end

    should "be the panel's once released" do
      CreatorTagRelease.set!("aichan_maple", released: true, by: @admin)
      CreatorVisibility.forget!

      assert_equal 200, status_for(@ai, @fan)
      assert_equal @ai.md5, md5_for(@ai, @fan)
      assert_nil md5_for(@ai, @stranger)
    end
  end

  # Q2: "admins only may view a post its creator hid; every such view is
  # logged." Moderators see nothing a creator hid, the log included.
  context "an admin's view" do
    should "log each page view of a post its creator hid, and nothing else" do
      get_auth post_path(@closed), @admin
      assert_response :success
      get_auth post_path(@closed), @admin
      assert_equal 2, views.where(subject: @closed, creator: @admin).count

      get_auth post_path(@closed, format: :json), @admin
      get_auth post_path(@closed, variant: "tooltip"), @admin
      get_auth post_path(@plain), @admin
      get_auth posts_path, @admin, params: { tags: "cvtest" }
      assert_equal 2, views.count, "JSON, a tooltip, an ordinary post and a listing log nothing"
    end

    # The Modulation viewer moves post to post through its JSON payload, so
    # that payload is an admin opening the post (review, 2026-10-08).
    # Review 2026-10-08: the viewer fetches payloads ahead (the neighbours)
    # and again after a vote, so a payload fetch is not a view; the client
    # says when it shows the post (?opened=1), and only for a payload that
    # says it is logged.
    should "log an admin's move to it in the Modulation viewer, and not a prefetch" do
      get_auth post_modulation_path(@closed), @admin
      assert_response :success
      assert response.parsed_body["logs_admin_view"]
      assert_equal 0, views.count, "a prefetch or a refresh is not a view"

      get_auth post_modulation_path(@closed), @admin, params: { opened: 1 }
      assert_equal 1, views.where(subject: @closed, creator: @admin).count
      # What the client sends: a HEAD of the same payload, the body unread.
      login_as(@admin)
      head post_modulation_path(@closed, format: :json, opened: 1)
      assert_response :success
      assert_equal 2, views.where(subject: @closed, creator: @admin).count
      get_auth post_modulation_path(@plain), @admin, params: { opened: 1 }
      assert_not response.parsed_body["logs_admin_view"]
      get_auth post_modulation_path(@closed), @named, params: { opened: 1 }
      assert_not response.parsed_body["logs_admin_view"]
      assert_equal views.where(subject: @closed).count, views.count, "an ordinary post or a let-in viewer logs nothing"
    end

    should "not log an admin the creator let in" do
      CreatorUserRule.set!(@gallery, @admin, rule: "allow", by: @maple, post: @closed)
      get_auth post_path(@closed), @admin
      assert_response :success
      assert_equal 0, views.count
    end

    should "show the entry to admins alone" do
      get_auth post_path(@closed), @admin
      [@moderator, @fan].each do |user|
        get_auth mod_actions_path(format: :json), user, params: { search: { category: ModAction.categories["creator_hidden_post_view"] }}
        assert_response :success
        assert_empty response.parsed_body, name_of(user)
      end
      get_auth mod_actions_path(format: :json), @admin, params: { search: { category: ModAction.categories["creator_hidden_post_view"] }}
      assert_equal [@closed.id], response.parsed_body.pluck("subject_id")
    end
  end

  # Matrix-posted images are served by the room-gated mxc route, not by this
  # stage: what the booru decides here is whether the post exists for the
  # viewer and whether its md5 is given out. A Matrix post narrowed by its
  # creator is out of every booru door like any other.
  context "a Matrix-posted image" do
    should "be narrowed on the booru like any other post" do
      mxc = maple_post("cvtest landscape")
      mxc.update!(source: "mxc://41chan.net/AbCdEf")
      CreatorPostAudience.set!(mxc, gallery: @gallery, audience: "private", by: @maple)
      CreatorVisibility.forget!

      assert_equal 404, status_for(mxc, @fan)
      assert_equal 200, status_for(mxc, @maple)
    end
  end

  # fourier-sampling-c2's check c (2026-10-08): the widen lifts the level gate
  # and nothing else. Not the safe-mode or ban gates beside it, and not past
  # anything else hidden_from? hides.
  context "a widened post" do
    should "still be held back by safe mode and a takedown" do
      assert @gated.visible?(@fan)
      CurrentUser.set(user: @fan, safe_mode: true) do
        assert @gated.safeblocked? unless @gated.rating == "g"
        assert_not @gated.visible?(@fan) unless @gated.rating == "g"
      end
      @gated.update!(is_banned: true)
      assert @gated.banblocked?(@fan)
      assert_not @gated.visible?(@fan)
    end

    should "not be opened where it is deleted, or under another creator's hidden prefix" do
      Danbooru.config.stubs(:deleted_post_visibility_level).returns(User::Levels::ADMIN)
      assert @gated.creator_allows?(@fan)

      as(@admin) { @gated.update!(tag_string: "#{@gated.tag_string} aichan_someone_else") }
      CreatorVisibility.forget!
      assert @gated.reload.hidden_from?(@fan)
      assert_not @gated.creator_allows?(@fan)
      assert_not PostPolicy.new(@fan, @gated).can_see_media?

      deleted = maple_post("cvtest #{GATED}")
      CreatorPostAudience.set!(deleted, gallery: @gallery, audience: "public", by: @maple, group_ids: [@tier.id])
      deleted.delete!("ordinary deletion", user: @admin)
      CreatorVisibility.forget!
      assert CreatorVisibility.widened_ids(@fan).include?(deleted.id), "fixture: in the widen set"
      assert_not deleted.reload.creator_allows?(@fan)
      assert_not PostPolicy.new(@fan, deleted).can_see_media?
    end
  end

  # Review 2026-10-08: find_writable! let the moderation tier past
  # hidden_from?, and a write answers with the whole post. Q2: moderators see
  # nothing a creator hid. They still act on a deleted post.
  context "a write" do
    should "be refused to a moderator for a post its creator hid, and still reach a deleted one" do
      Danbooru.config.stubs(:deleted_post_visibility_level).returns(User::Levels::ADMIN)
      put_auth post_path(@closed, format: :json), @moderator, params: { post: { tag_string: "#{@closed.tag_string} cv_edit" }}
      assert_response 404
      assert_not_includes @closed.reload.tag_array, "cv_edit"

      deleted = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "cvtest") }
      deleted.delete!("ordinary deletion", user: @admin)
      assert deleted.reload.hidden_from?(@moderator), "fixture: deleted is hidden from a moderator"
      put_auth post_path(deleted, format: :json), @moderator, params: { post: { tag_string: "cvtest cv_edit" }}
      assert_response :success
      assert_includes deleted.reload.tag_array, "cv_edit"

      put_auth post_path(@closed, format: :json), @named, params: { post: { tag_string: "#{@closed.tag_string} cv_edit" }}
      assert_response :success
    end

    # Review 2026-10-08: the doors that file a row on a post by its id never
    # asked, and POST /favorites.json answered the whole post -- md5, source,
    # tags -- to any member. One rule now, in ApplicationController#authorize,
    # for every row a write names (Post#writable_by?).
    should "refuse a favorite, a vote, a comment or a comment vote on it, as on a missing post" do
      comment = as(@named) { create(:comment, post: @closed) }
      post_auth favorites_path(format: :json), @stranger, params: { post_id: @closed.id }
      assert_response 404
      assert_not_includes response.body, @closed.md5
      post_auth post_post_votes_path(post_id: @closed.id, format: :json), @stranger, params: { score: 1 }
      assert_response 404
      post_auth comments_path(format: :json), @stranger, params: { comment: { post_id: @closed.id, body: "cv probe" }}
      assert_response 404
      post_auth comment_comment_votes_path(comment_id: comment.id, format: :json), @stranger, params: { score: 1 }
      assert_response 404
      assert_equal 0, Favorite.where(post: @closed).count
      assert_equal 0, PostVote.where(post: @closed).count
      assert_equal [comment.id], Comment.where(post: @closed).pluck(:id)
      assert_equal 0, CommentVote.where(comment: comment).count

      post_auth favorites_path(format: :json), @named, params: { post_id: @closed.id }
      assert_response :success
      post_auth favorites_path(format: :json), @stranger, params: { post_id: @plain.id }
      assert_response :success
    end

    # Review 2026-10-08: find_writable! reached four doors; these answered a
    # moderator with the whole post, or its state, for a post they cannot see.
    should "refuse a moderator's delete, regeneration, ban and moderation pill on it" do
      delete_auth post_path(@closed, format: :json), @moderator
      assert_response 404
      post_auth post_regenerations_path(format: :json), @moderator, params: { post_id: @closed.id, category: "iqdb" }
      assert_response 404
      post_auth ban_moderator_post_post_path(@closed, format: :json), @moderator
      assert_response 404
      get_auth confirm_move_favorites_moderator_post_post_path(@closed), @moderator
      assert_response 404
      method_authenticated(:patch, modulation_moderation_path(post_id: @closed.id, format: :json), @moderator, params: { deleted: true })
      assert_response 404
      assert_not @closed.reload.is_deleted?
      assert_not @closed.is_banned?

      post_auth ban_moderator_post_post_path(@plain, format: :json), @moderator
      assert_response :success
      assert @plain.reload.is_banned?
    end
  end

  # Review 2026-10-08: the relationship notices were built from every row.
  context "the post page's relationship notices" do
    setup do
      @parent = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "cvtest") }
      @child = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "cvtest") }
      as(@admin) do
        @closed.update!(parent_id: @parent.id)
        @child.update!(parent_id: @closed.id)
      end
      CreatorVisibility.forget!
    end

    should "neither count nor link a child its creator hid" do
      assert_not_includes body_for(post_path(@parent), @stranger), "post-notice-parent"
      assert_includes body_for(post_path(@parent), @named), "post-notice-parent"
    end

    should "neither name nor link a parent its creator hid" do
      # The link's search is URL-encoded in the page (parent%3A<id>).
      named = /parent(:|%3A)#{@closed.id}\b/
      page = body_for(post_path(@child), @stranger)
      assert_not_includes page, "post-notice-child"
      assert_no_match named, page
      assert_match named, body_for(post_path(@child), @named)
    end

    should "say the same in the Modulation payload" do
      kinds = ->(post, user) { get_auth(post_modulation_path(post), user) && response.parsed_body["notices"].to_a.pluck("kind") }
      assert_not_includes kinds.call(@parent, @stranger), "child"
      assert_not_includes kinds.call(@child, @stranger), "parent"
      assert_includes kinds.call(@child, @named), "parent"
    end

    # Review 2026-10-08: the payload counted a DELETED child, which the page
    # leaves out, so a post whose only live child was hidden still said it
    # had children there.
    should "not count a deleted child where the page does not, in either" do
      dead = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "cvtest", parent_id: @parent.id) }
      dead.delete!("ordinary deletion", user: @admin)
      assert @parent.reload.has_active_children?, "fixture: the hidden child is live"
      kinds = ->(post, user) { get_auth(post_modulation_path(post), user) && response.parsed_body["notices"].to_a.pluck("kind") }

      assert_not_includes kinds.call(@parent, @stranger), "child"
      assert_not_includes body_for(post_path(@parent), @stranger), "post-notice-parent"
      assert_includes kinds.call(@parent, @named), "child"
    end
  end

  context "a post's comments" do
    should "not answer for a post its creator hid" do
      get_auth comments_path(post_id: @closed.id), @stranger, xhr: true
      assert_response 404
      get_auth comments_path(post_id: @closed.id), @named, xhr: true
      assert_response :success
    end
  end

  # Review 2026-10-08: /media_assets/:id printed "Post #N", sources and
  # uploaders for a post whose own page was a 404.
  context "a media asset" do
    should "answer as its post does" do
      asset = @closed.media_asset
      get_auth media_asset_path(asset, format: :json), @stranger
      assert_response 404
      get_auth media_asset_path(asset), @stranger
      assert_response 404
      get_auth media_asset_path(asset, format: :json), @named
      assert_response :success

      listed = ->(user) { get_auth(media_assets_path(format: :json), user, params: { limit: 100 }) && response.parsed_body.pluck("id") }
      assert_not_includes listed.call(@stranger), asset.id
      assert_includes listed.call(@named), asset.id
      assert_includes listed.call(@stranger), @plain.media_asset.id
    end
  end

  # Review 2026-10-08: a pool's post_ids, count and navigation named every
  # post; adding one was an existence oracle.
  context "a pool and a favorite group" do
    setup do
      @last = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "cvtest") }
      @ids = [@plain.id, @closed.id, @last.id]
      @pool = as(@named) { create(:pool, name: "cv_pool", post_ids: @ids) }
      @favgroup = as(@named) { create(:favorite_group, creator: @named, post_ids: @ids) }
      CreatorVisibility.forget!
    end

    should "list, count and step over only the posts that exist for the viewer" do
      get_auth pool_path(@pool, format: :json), @stranger
      assert_equal [@plain.id, @last.id], response.parsed_body["post_ids"]
      assert_equal 2, response.parsed_body["post_count"]
      get_auth pool_path(@pool, format: :json), @named
      assert_equal @ids, response.parsed_body["post_ids"]
      get_auth favorite_group_path(@favgroup, format: :json), @stranger
      assert_equal [@plain.id, @last.id], response.parsed_body["post_ids"]

      CurrentUser.scoped(@stranger) do
        assert_equal @last.id, @pool.next_post_id(@plain.id)
        assert_equal 2, @pool.page_number(@last.id)
        assert_equal @last.id, @favgroup.next_post_id(@plain.id)
      end
      CurrentUser.scoped(@named) { assert_equal @closed.id, @pool.next_post_id(@plain.id) }
    end

    should "not tell a hidden post from a missing one when adding it" do
      fans = as(@stranger) { create(:favorite_group, creator: @stranger) }
      post_auth pool_element_path(format: :json), @stranger, params: { pool_id: @pool.id, post_id: @closed.id }
      assert_response 404
      put_auth add_post_favorite_group_path(fans, format: :json), @stranger, params: { post_id: @closed.id }
      assert_response 404
      put_auth favorite_group_path(fans, format: :json), @stranger, params: { favorite_group: { post_ids_string: @closed.id.to_s }}
      assert_equal [], fans.reload.post_ids
      put_auth add_post_favorite_group_path(fans, format: :json), @stranger, params: { post_id: @plain.id }
      assert_response :success
    end

    should "keep the posts an editor cannot see when they save the visible list, where they were" do
      extra = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "cvtest") }
      put_auth pool_path(@pool), @stranger, params: { pool: { post_ids_string: "#{@plain.id} #{@last.id} #{extra.id}" }}
      assert_equal [@plain.id, @closed.id, @last.id, extra.id], @pool.reload.post_ids, "an append moves nothing"

      put_auth pool_path(@pool), @stranger, params: { pool: { post_ids_string: "#{@last.id} #{extra.id}" }}
      assert_equal [@closed.id, @last.id, extra.id], @pool.reload.post_ids, "behind a removed post, it keeps its place"

      put_auth favorite_group_path(@favgroup), @named, params: { favorite_group: { post_ids_string: "#{@plain.id} #{@closed.id} #{@last.id} #{extra.id}" }}
      assert_equal [@plain.id, @closed.id, @last.id, extra.id], @favgroup.reload.post_ids
      put_auth pool_path(@pool), @named, params: { pool: { post_ids_string: @last.id.to_s }}
      assert_equal [@last.id], @pool.reload.post_ids, "what an editor can see, they can remove"
    end

    # The post page's pool bar links the first and last page; they are the
    # first and last that exist for the viewer.
    should "not link a hidden post as the first page in the pool bar" do
      as(@named) { @pool.update!(post_ids: [@closed.id, @plain.id, @last.id]) }
      closed_link = %r{/posts/#{@closed.id}\b}
      page = body_for(post_path(@plain), @stranger, q: "pool:#{@pool.id}")
      assert_includes page, "pool-navbar"
      assert_no_match closed_link, page
      assert_match closed_link, body_for(post_path(@plain), @named, q: "pool:#{@pool.id}")
    end

    # Review 2026-10-08: each pool on a page asked about its own ids, one
    # query a row -- a thousand for /pools.json?limit=1000.
    should "decide a page of pools in one query, however many it lists" do
      # Deleted posts hidden from members, as in production, so there is a
      # term for the database to answer (creator-hidden ids are in memory).
      Danbooru.config.stubs(:deleted_post_visibility_level).returns(User::Levels::ADMIN)
      reads = lambda do
        pools = Pool.order(:id).to_a
        queries_during { Pool.preload_visible_post_ids(pools, @stranger).each { |pool| 2.times { pool.visible_post_ids(@stranger) } } }
      end
      reads.call # the viewer's hidden set, once per request
      few = reads.call
      3.times { |i| as(@named) { create(:pool, name: "cv_pool_#{i}", post_ids: [@plain.id, @closed.id]) } }

      assert_equal 1, few
      assert_equal few, reads.call
    end

    # Review 2026-10-08: the stored lists are whole, so searching pools by a
    # hidden post's id found the pools holding it.
    should "not be found by a hidden post's id" do
      search = ->(path, user, **params) { get_auth(path, user, params: { search: params }) && response.parsed_body.pluck("id") }
      assert_empty search.call(pools_path(format: :json), @stranger, post_ids_include_any: @closed.id.to_s)
      assert_empty search.call(pools_path(format: :json), @stranger, post_ids_include_all: "#{@plain.id} #{@closed.id}")
      assert_empty search.call(pools_path(format: :json), @stranger, post_ids_include_any_array: [@closed.id])
      assert_equal [@pool.id], search.call(pools_path(format: :json), @stranger, post_ids_include_any: "#{@closed.id} #{@plain.id}")
      assert_equal [@pool.id], search.call(pools_path(format: :json), @named, post_ids_include_any: @closed.id.to_s)
      assert_empty search.call(favorite_groups_path(format: :json), @stranger, post_ids_include_any: @closed.id.to_s)

      get_auth pools_path(format: :json), @stranger, params: { search: { any_post_id_matches_regex: "." }}
      assert_response 400
    end
  end

  # Review 2026-10-08: tag names that exist only on hidden posts.
  context "a tag that exists only on posts its creator hid" do
    setup do
      as(@admin) { @closed.update!(tag_string: "#{@closed.tag_string} cv_secret_oc") }
      CreatorVisibility.forget!
    end

    should "not be listed, autocompleted or offered as related to whoever those posts are hidden from" do
      assert_includes Tag.hidden_names_for(@stranger), "cv_secret_oc"
      assert_not_includes Tag.hidden_names_for(@named), "cv_secret_oc"
      assert_not_includes Tag.hidden_names_for(@stranger), "landscape", "also on a post the viewer can see"

      get_auth tags_path(format: :json), @stranger, params: { search: { name: "cv_secret_oc" }}
      assert_empty response.parsed_body
      get_auth tags_path(format: :json), @named, params: { search: { name: "cv_secret_oc" }}
      assert_equal ["cv_secret_oc"], response.parsed_body.pluck("name")

      suggest = ->(user) { AutocompleteService.new("cv_secret", :tag_query, current_user: user, enabled: true).autocomplete_results.map(&:value) }
      assert_not_includes suggest.call(@stranger), "cv_secret_oc"
      assert_includes suggest.call(@named), "cv_secret_oc"
    end

    should "never be cached publicly for a signed-in viewer" do
      assert_not AutocompleteService.new("cv_secret", :tag_query, current_user: @named).cache_publicly?
      assert AutocompleteService.new("cv_secret", :tag_query, current_user: User.anonymous).cache_publicly?
    end
  end

  # Review 2026-10-08: the pulse cached per level while its query carried a
  # viewer-specific -id list.
  context "the archive pulse" do
    should "not share an entry between viewers who see different posts, and share one between two strangers" do
      key = ->(user) { ArchivePulse.new(viewer: user).send(:hidden_digest) }
      assert_not_equal key.call(@stranger), key.call(@fan)
      assert_equal key.call(@stranger), key.call(create(:user))
    end
  end

  # CLAUDE.md "The front page: the hero band" (operator, 2026-10-08): the
  # band is the anonymous draw, and a tenant answers what a signed-out
  # visitor may reach through it. A post its creator hid is in it for nobody
  # the creator did not let in.
  context "the hero band" do
    should "carry a post its creator hid only to whoever the creator let in" do
      board = "https://boards.4chan.org/b/thread/953493575#p953493576"
      hidden = as(@tunnel) { create(:post, uploader: @tunnel, source: board, tag_string: "cvband") }
      FourierPostCreator.create!(post: hidden, mxid: "@maple:41chan.net", recorded_by: @tunnel.id)
      CreatorPostAudience.set!(hidden, gallery: @gallery, audience: "private", by: @maple)
      CreatorUserRule.set!(@gallery, @named, rule: "allow", by: @maple, post: hidden)
      shown = as(@tunnel) { create(:post, uploader: @tunnel, source: board, tag_string: "cvband") }
      CreatorVisibility.forget!

      ids = ->(user) { LandingShowcase.new(viewer: user).categories.flat_map { |c| c[:slides].to_a.pluck(:id) } }
      [User.anonymous, @stranger, @fan, @moderator].each do |user|
        slides = ids.call(user)
        assert_includes slides, shown.id, "fixture: the band draws #{name_of(user)} a board post"
        assert_not_includes slides, hidden.id, name_of(user)
      end
      assert_includes ids.call(@named), hidden.id
    end

    # Review 2026-10-08: the creator lamps -- the band's pills, the post
    # page's and their anonymous poll -- counted every post, so a private
    # post lit its creator's lamp for everyone and the poll confirmed tag
    # names that exist only on hidden posts.
    should "light a creator's lamp only for a post that exists for the viewer" do
      secret = maple_post("cvlamp_secret")
      CreatorPostAudience.set!(secret, gallery: @gallery, audience: "private", by: @maple)
      CreatorUserRule.set!(@gallery, @named, rule: "allow", by: @maple, post: secret)
      CreatorVisibility.forget!

      lit = ->(user) { get_as(user, modulation_creator_activity_path(format: :json), tags: "cvlamp_secret") && response.parsed_body["active"] }
      [nil, @stranger, @fan, @moderator].each { |user| assert_empty lit.call(user), name_of(user) }
      [@named, @maple].each { |user| assert_equal ["cvlamp_secret"], lit.call(user), name_of(user) }

      assert_empty CreatorActivity.active(["cvlamp_secret"], viewer: User.anonymous)
      shown = maple_post("cvlamp_shown")
      assert_equal ["cvlamp_shown"], CreatorActivity.active(%w[cvlamp_secret cvlamp_shown], viewer: User.anonymous), "fixture: a public post lights it"
      assert shown
    end
  end

  # Second review, 2026-10-08: the doors that reach a post through something
  # other than belongs_to :post, which the general rule did not see.
  context "an AI tag" do
    setup do
      @ai_tag = AITag.create!(media_asset: @closed.media_asset, tag: Tag.find_or_create_by_name("cv_ai_guess"), score: 90)
    end

    should "not be listed, nor tag the post, for whoever its post is hidden from" do
      listed = ->(user) { get_auth(ai_tags_path(format: :json), user, params: { search: { media_asset_id: @closed.media_asset.id }}) && response.parsed_body.pluck("tag_id") }
      assert_empty listed.call(@stranger)
      assert_empty listed.call(@moderator)
      assert_equal [@ai_tag.tag_id], listed.call(@named)

      before = [@closed.tag_string, @closed.rating]
      tag = ->(user, value) { put_auth(tag_ai_tag_path(media_asset_id: @ai_tag.media_asset_id, tag_id: @ai_tag.tag_id, format: :json), user, params: { tag: value }) }
      tag.call(@stranger, "rating:e")
      assert_response 404
      tag.call(@moderator, "cv_vandal")
      assert_response 404
      assert_equal before, [@closed.reload.tag_string, @closed.rating]

      tag.call(@named, "cv_named_tag")
      assert_includes @closed.reload.tag_array, "cv_named_tag"
    end
  end

  # Second review, 2026-10-08: child:, parent: and post[parent_id] on the
  # editor's own post wrote onto a post its creator hid, and told a hidden
  # id from a missing one.
  context "a relationship named from a post the editor can see" do
    setup do
      @mine = as(@stranger) { create(:post, uploader: @stranger, tag_string: "cvtest mine") }
      @missing = Post.maximum(:id) + 1000
    end

    should "not make it a child" do
      put_auth post_path(@mine, format: :json), @stranger, params: { post: { tag_string: "cvtest mine child:#{@closed.id}" }}
      assert_response :success
      assert_nil @closed.reload.parent_id
      assert_not response.parsed_body["has_children"]
    end

    should "not release a hidden child with child:none or -child:" do
      as(@admin) { @closed.update!(parent_id: @mine.id) }
      put_auth post_path(@mine, format: :json), @stranger, params: { post: { tag_string: "cvtest mine child:none" }}
      put_auth post_path(@mine, format: :json), @stranger, params: { post: { tag_string: "cvtest mine -child:#{@closed.id}" }}
      assert_equal @mine.id, @closed.reload.parent_id
    end

    should "refuse it as a parent exactly as a missing post" do
      answer = lambda do |params|
        put_auth post_path(@mine, format: :json), @stranger, params: { post: params }
        [response.status, response.parsed_body.except("backtrace").to_s.gsub(/#{@closed.id}|#{@missing}/o, "N"), @mine.reload.parent_id]
      end
      assert_equal answer.call(parent_id: @missing), answer.call(parent_id: @closed.id)
      assert_equal answer.call(tag_string: "cvtest mine parent:#{@missing}"), answer.call(tag_string: "cvtest mine parent:#{@closed.id}")
      assert_nil @mine.reload.parent_id
      assert_not @closed.reload.has_children?

      put_auth post_path(@mine, format: :json), @named, params: { post: { parent_id: @closed.id }}
      assert_equal @closed.id, @mine.reload.parent_id, "the user the creator named may"
    end

    should "not move a child's favorites onto it, nor offer to" do
      kid = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "cvtest") }
      as(@admin) { kid.update!(parent_id: @closed.id) }
      create(:favorite, post: kid, user: @fan)
      delete_auth post_path(kid), @moderator, params: { commit: "Delete", post: { reason: "cv duplicate", move_favorites: "1" }}
      assert kid.reload.is_deleted?, "fixture: the moderator deleted the child"
      assert_equal 0, Favorite.where(post: @closed).count

      assert_not_includes body_for(post_path(kid), @moderator), "post-option-move-favorites"
      post_auth move_favorites_moderator_post_post_path(kid), @moderator, params: { commit: "Submit" }
      assert_equal 0, Favorite.where(post: @closed).count
      assert_includes body_for(post_path(kid), @admin), "post-option-move-favorites", "an admin is told of the parent"
    end
  end

  # Second review, 2026-10-08: a visible relative's JSON, thumbnail and
  # page attributes named the hidden post, and parent:<its id> found its
  # children.
  context "a visible relative" do
    setup do
      @parent = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "cvtest") }
      @child = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "cvtest") }
      as(@admin) do
        @closed.update!(parent_id: @parent.id)
        @child.update!(parent_id: @closed.id)
      end
      CreatorVisibility.forget!
    end

    should "not name or count it in its JSON" do
      json = ->(post, user) { get_auth(post_path(post, format: :json), user) && response.parsed_body }
      flags = %w[has_children has_active_children has_visible_children]
      assert_nil json.call(@child, @stranger)["parent_id"]
      assert_equal [false, false, false], json.call(@parent, @stranger).values_at(*flags)
      assert_equal @closed.id, json.call(@child, @named)["parent_id"]
      assert_equal [true, true, true], json.call(@parent, @named).values_at(*flags)

      get_auth posts_path(format: :json), @stranger, params: { tags: "id:#{@parent.id},#{@child.id}" }
      assert_equal [[nil, false]], response.parsed_body.map { |post| [post["parent_id"], post["has_children"]] }.uniq
    end

    should "not mark its thumbnail or page with it" do
      marked = /post-status-has-(parent|children)/
      assert_no_match marked, body_for(posts_path, @stranger, tags: "id:#{@parent.id},#{@child.id}")
      assert_match marked, body_for(posts_path, @named, tags: "id:#{@parent.id},#{@child.id}")
      assert_no_match(/data-post-parent-id="#{@closed.id}"/, body_for(post_path(@child), @stranger))
      assert_match(/data-post-parent-id="#{@closed.id}"/, body_for(post_path(@child), @named))
      assert_match(/data-post-has-children="false"/, body_for(post_path(@parent), @stranger))
    end

    should "not be found by parent:<its id>" do
      assert_empty ids_for(@stranger, "parent:#{@closed.id}")
      assert_equal [@parent.id, @child.id].sort, ids_for(@stranger, "-parent:#{@closed.id} cvtest").select { |id| [@parent.id, @child.id].include?(id) }.sort
      assert_equal [@closed.id, @child.id].sort, ids_for(@named, "parent:#{@closed.id}").sort
    end
  end

  # Second review, 2026-10-08: tags#show answered a name that exists only on
  # hidden posts, by id, to anyone -- the name the tag index withholds.
  context "a tag by id" do
    setup do
      as(@admin) { @closed.update!(tag_string: "#{@closed.tag_string} cv_secret_oc") }
      @secret = Tag.find_by_name!("cv_secret_oc")
      CreatorVisibility.forget!
    end

    should "answer as a missing tag to whoever its posts are hidden from" do
      [nil, @stranger, @moderator].each do |user|
        get_as(user, tag_path(@secret, format: :json))
        assert_response 404, name_of(user)
      end
      get_as(@stranger, tag_path(Tag.find_by_name!("landscape"), format: :json))
      assert_response :success
      [@named, @maple].each do |user|
        get_as(user, tag_path(@secret, format: :json))
        assert_response :success, name_of(user)
      end
    end
  end

  # Second review, 2026-10-08: /user_actions put each branch through
  # ApplicationRecord.visible, which keeps every row.
  context "a user's actions" do
    should "not list a post its creator hid, nor a row filed on it" do
      comment = as(@named) { create(:comment, post: @closed, creator: @named) }
      as(@maple) { create(:comment_vote, comment: comment, user: @maple, score: 1) }
      rows = ->(user, actor) { get_auth(user_actions_path(format: :json), user, params: { search: { user_id: actor.id }, limit: 100 }) && response.parsed_body.map { |row| [row["model_type"], row["model_id"]] } }

      tunnel = rows.call(@moderator, @tunnel)
      assert_includes tunnel, ["Post", @plain.id]
      assert_not_includes tunnel, ["Post", @closed.id]
      assert_not_includes rows.call(@moderator, @named), ["Comment", comment.id]
      assert_not_includes rows.call(@moderator, @maple).map(&:first), "CommentVote"

      assert_includes rows.call(@admin, @tunnel), ["Post", @closed.id]
      assert_includes rows.call(@admin, @named), ["Comment", comment.id]
      assert_includes rows.call(@admin, @maple).map(&:first), "CommentVote"
    end
  end

  # Second review, 2026-10-08: a hidden post answered 404 at a write door
  # where a missing one answered 500 or 422 -- the oracle moved, not shut.
  context "a write naming a post by id" do
    should "answer a missing post and a hidden one the same" do
      missing = Post.maximum(:id) + 1000
      doors = {
        "favorite" => ->(id) { post_auth(favorites_path(format: :json), @stranger, params: { post_id: id }) },
        "vote" => ->(id) { post_auth(post_post_votes_path(post_id: id, format: :json), @stranger, params: { score: 1 }) },
        "comment" => ->(id) { post_auth(comments_path(format: :json), @stranger, params: { comment: { post_id: id, body: "cv probe" }}) },
        "note" => ->(id) { post_auth(notes_path(format: :json), @stranger, params: { note: { post_id: id, x: 1, y: 1, width: 10, height: 10, body: "cv" }}) },
        "flag" => ->(id) { post_auth(post_flags_path(format: :json), @stranger, params: { post_flag: { post_id: id, reason: "cv probe" }}) },
        "commentary" => ->(id) { put_auth(create_or_update_artist_commentaries_path(format: :json), @stranger, params: { artist_commentary: { post_id: id, original_title: "cv" }}) },
      }
      doors.each do |door, call|
        answers = [missing, @closed.id].map do |id|
          call.call(id)
          [response.status, response.body.gsub(id.to_s, "N")]
        end
        assert_equal answers.first, answers.last, door
        assert_equal 404, answers.last.first, door
      end
    end
  end

  # Second review, 2026-10-08: the write rule also froze a member's own
  # favorite and vote once the post was hidden from them. Withdrawing your
  # own row discloses nothing; the answer still carries nothing of the post.
  context "a row the viewer filed before the post was hidden from them" do
    should "be theirs to withdraw, with an answer that names nothing" do
      create(:favorite, post: @closed, user: @stranger)
      vote = create(:post_vote, post: @closed, user: @stranger, score: 1)
      comment = as(@named) { create(:comment, post: @closed) }
      comment_vote = create(:comment_vote, comment: comment, user: @stranger, score: 1)

      delete_auth favorite_path(@closed.id), @stranger, xhr: true
      assert_response 204
      assert_empty response.body
      assert_equal 0, Favorite.where(post: @closed, user: @stranger).count

      delete_auth post_vote_path(vote), @stranger, xhr: true
      assert_response 204
      assert vote.reload.is_deleted?

      delete_auth comment_vote_path(comment_vote), @stranger, xhr: true
      assert_response 204
      assert_empty response.body
      assert comment_vote.reload.is_deleted?

      other = create(:post_vote, post: @closed, user: @fan, score: 1)
      delete_auth post_vote_path(other), @stranger, xhr: true
      assert_response 404
      assert_not other.reload.is_deleted?
    end
  end

  # Second review, 2026-10-08: /pool_versions still matched a hidden post's id.
  context "a pool's history" do
    setup do
      @pool = as(@named) { create(:pool, name: "cv_history", post_ids: [@plain.id, @closed.id]) }
      # The archive service computes a version's diff; the test double does
      # not, so give the first version the one it would have.
      PoolVersion.where(pool_id: @pool.id).find_each { |version| version.update!(added_post_ids: [@plain.id, @closed.id]) }
    end

    should "not be found by a hidden post's id" do
      search = ->(user, **params) { get_auth(pool_versions_path(format: :json), user, params: { search: params }) && response.parsed_body.pluck("pool_id").uniq }
      assert_empty search.call(@stranger, post_id: @closed.id)
      assert_empty search.call(@stranger, added_post_ids_include_any: @closed.id.to_s)
      assert_empty search.call(@stranger, post_ids_include_all: "#{@plain.id} #{@closed.id}")
      assert_equal [@pool.id], search.call(@stranger, post_id: @plain.id)
      assert_equal [@pool.id], search.call(@named, post_id: @closed.id)
      assert_equal [@pool.id], search.call(@named, added_post_ids_include_any: @closed.id.to_s)

      get_auth pool_versions_path(format: :json), @stranger, params: { search: { any_added_post_id_matches_regex: "." }}
      assert_response 400
    end
  end
end
