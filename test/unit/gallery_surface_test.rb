# frozen_string_literal: true

require "test_helper"

# GallerySurface decides what the post index offers a viewer (interfaces
# stage 1, step 4b); the Modulation gallery and its grid draw what it returns,
# on the page and in the window's chunks. What each viewer is offered is
# pinned by the parity and privacy recordings; this pins the shape that makes
# them hold for every interface: the surface decides for the viewer it is
# handed, never for CurrentUser, a thumbnail it cannot decide draws as gated
# and says so, and the components decide nothing.
class GallerySurfaceTest < ActiveSupport::TestCase
  include TagQuarantineTestHelper

  COMPONENTS = %w[
    app/interfaces/modulation/components/modulation_gallery_component.rb
    app/interfaces/modulation/components/modulation_gallery_component/modulation_gallery_component.html.erb
    app/interfaces/modulation/components/modulation_gallery_component/grid_component.rb
    app/interfaces/modulation/components/modulation_gallery_component/grid_component.html.erb
  ].freeze
  # A viewer, a decision, a policy or a query: what the components must leave
  # to the surface. Matched with comments removed, which name the viewer
  # freely.
  DECIDING = /\b(?:CurrentUser|current_user|viewer)\b|\bMembersOnly\b|Policy\b|\bpolicy\(|\.visible\?|\.(?:pending|count|where|find_by|pluck)\b|\b(?:ModulationSetting|SessionObservation|TagQuarantine|TagBanishment|FourierTagSource|CharacterClaim)\b/

  def surface_for(viewer, tags = "")
    request = ActionDispatch::TestRequest.create
    post_set = PostSets::Post.new(tags, nil, nil, user: viewer, window: :page)
    GallerySurface.new(post_set: post_set, viewer: viewer, request: request, session: request.session)
  end

  context "GallerySurface" do
    setup do
      @owner = create(:owner_user)
      @post = as(@owner) { create(:post, tag_string: "gsurface") }
    end

    should "decide for the viewer it is handed, never for CurrentUser" do
      Danbooru.config.stubs(:anonymous_default_deny?).returns(true)

      signed_out = CurrentUser.scoped(@owner) { surface_for(User.anonymous) }
      owner = CurrentUser.scoped(User.anonymous) { surface_for(@owner) }

      assert_equal(false, CurrentUser.scoped(@owner) { signed_out.searchable? }, "the signed-out search box was decided for CurrentUser (the owner); fix: GallerySurface asks its `viewer`, never CurrentUser")
      assert_equal(false, CurrentUser.scoped(@owner) { signed_out.can_browse? }, "the signed-out browse check was decided for CurrentUser (the owner); fix: GallerySurface asks its `viewer`, never CurrentUser")
      assert_equal(true, CurrentUser.scoped(User.anonymous) { owner.searchable? }, "the owner's search box was decided for CurrentUser (signed out); fix: GallerySurface asks its `viewer`, never CurrentUser")
      assert_equal(true, CurrentUser.scoped(User.anonymous) { owner.can_browse? })
    end

    # These two filters are the surface's own guard behind earlier ones: the
    # post search drops a post carrying a name hidden from the viewer, and the
    # post set's sidebar drops hidden names, so no page the recordings draw
    # ever hands them a banished name. The test hands them one directly.
    should "withhold a banished name handed to it from the facet tags and the card categories" do
      banish_tags!("gs_banished")
      surface = surface_for(create(:user), "gsurface")
      surface.post_set.stubs(:sidebar_tags).returns(Tag.where(name: %w[gsurface gs_banished]).to_a)
      surface.stubs(:blacklist_tags).returns({ @post => %w[gsurface gs_banished] })

      assert_equal(["gsurface"], surface.visible_sidebar_tags.map(&:name), "a banished name was offered as a facet tag; fix: GallerySurface#visible_sidebar_tags filters through TagBanishment")
      assert_includes(surface.page_tag_categories.keys, "gsurface", "fixture: the shown post's ordinary tag is categorised")
      assert_not_includes(surface.page_tag_categories.keys, "gs_banished", "a banished name reached the card categories; fix: GallerySurface#page_tag_categories filters through TagBanishment")
    end

    # The leak this closes (2026-11-18): the gallery drew a gated card for a
    # banned post, so a Member's page named the id upstream omits.
    should "omit a banned post below Approver, and draw it for an Approver" do
      banned = as(@owner) { create(:post, tag_string: "gsurface", is_banned: true) }

      [create(:restricted_user), create(:user), create(:gold_user)].each do |viewer|
        listed = surface_for(viewer, "gsurface").posts.map(&:id)

        assert_includes(listed, @post.id, "fixture: the ordinary post is listed for #{viewer.level_string}")
        assert_not_includes(listed, banned.id, "a banned post was handed to the gallery for #{viewer.level_string}, which draws its id; fix: GallerySurface#posts selects through PostPreviewComponent.listed?")
      end

      approver = surface_for(create(:approver_user), "gsurface")

      assert_includes(approver.posts.map(&:id), banned.id, "a banned post was withheld from an Approver, who may see it")
      assert_not_nil(approver.thumb_for(approver.posts.find { |post| post.id == banned.id }), "an Approver's banned post was drawn gated; upstream draws it")
    end

    # The query drops a banned and a taken-down post from the window too
    # (PostSets::Post#window_query), so this hands the surface rows that hold
    # them directly: the surface is the guard that does not depend on the
    # query.
    should "omit every post the viewer may not list from rows the query hands it" do
      banned = as(@owner) { create(:post, tag_string: "gsurface", is_banned: true) }
      taken_down = as(@owner) { create(:post, tag_string: "gsurface", is_taken_down: true) }
      member = create(:user)
      surface = surface_for(member, "gsurface")
      surface.post_set.stubs(:posts).returns(Post.where(id: [@post.id, banned.id, taken_down.id]).order(id: :desc).to_a)

      assert_equal([@post.id], surface.posts.map(&:id), "a post the Member may not list reached the gallery; fix: GallerySurface#posts selects through PostPreviewComponent.listed?")
      [banned, taken_down].each do |post|
        assert_equal(false, PostPreviewComponent.listed?(post, member), "fixture: post ##{post.id} is not listed for a Member")
      end
    end

    # A listed post whose image is withheld keeps its designed gated face.
    # The one real case is safe mode (Post#safeblocked?): the post exists
    # for the viewer, only its image is withheld. Stubbed on the post, since
    # a safe-mode search leaves a non-g post out of the rows itself.
    should "keep a listed post it may not show in safe mode, drawn as gated" do
      member = create(:user)
      Post.any_instance.stubs(:safeblocked?).returns(true)
      surface = surface_for(member, "gsurface")
      drawn = surface.posts.find { |post| post.id == @post.id }

      assert_not_nil(drawn, "a listed post whose image safe mode withholds was dropped; the gallery draws it as a gated card")
      assert_equal(false, drawn.levelblocked?(member), "fixture: the post is not level-gated")
      assert_equal(true, PostPreviewComponent.listed?(drawn, member))
      assert_equal(false, PostPreviewComponent.drawable?(drawn, member), "fixture: upstream omits this post")
      assert_nil(surface.thumb_for(drawn), "a post whose image is withheld was handed a thumbnail; fix: GallerySurface#thumb_for answers nil, drawn as gated")
    end

    # A level-gated post (Post#levelblocked?, which is Gate 1's
    # hidden_as_gated?) does not exist for the viewer, so it is omitted, as
    # upstream omits it -- never drawn gated. Gate 1 stubbed on the post: the
    # search's own gated terms (PostQuery#gated_metatags) would leave a real
    # one out of the rows before the surface is asked.
    should "omit a level-gated post, never draw it gated" do
      member = create(:user)
      Post.any_instance.stubs(:hidden_as_gated?).returns(true)
      surface = surface_for(member, "gsurface")

      assert_equal(true, @post.levelblocked?(member), "fixture: the post is level-gated")
      assert_equal(false, PostPreviewComponent.listed?(@post, member), "a level-gated post was listed; fix: PostPreviewComponent.listed? asks Post#hidden_beyond_deletion?, which holds Gate 1")
      assert_not_includes(surface.posts.map(&:id), @post.id, "a level-gated post reached the gallery, which would draw its id on a gated card; fix: GallerySurface#posts selects through PostPreviewComponent.listed?")
    end

    should "draw a card it cannot decide as gated, and log the post, the error and the fix" do
      surface = surface_for(@owner, "gsurface")
      @post.stubs(:visible?).raises(ActiveRecord::ConnectionNotEstablished, "injected")
      logged = []
      Rails.logger.stubs(:error).with { |message| logged << message }

      assert_nil(surface.thumb_for(@post), "a thumbnail that raised was drawn; fix: GallerySurface#thumb_for fails closed (nil, drawn as gated)")
      assert_equal(1, logged.size, "a thumbnail that raised said nothing; fix: GallerySurface#thumb_for logs it")
      assert_match(/post ##{@post.id} drew as gated for user ##{@owner.id}: ActiveRecord::ConnectionNotEstablished: injected .*fix: /, logged.first)
    end
  end

  context "The Modulation gallery's components" do
    should "decide nothing: no viewer, policy or query of their own" do
      found = COMPONENTS.flat_map do |path|
        source = Rails.root.join(path).read
        source = path.end_with?(".erb") ? source.gsub(/<%#.*?%>/m) { |c| "\n" * c.count("\n") } : source.gsub(/^\s*#.*$/, "")
        source.lines.each_with_index.filter_map { |line, i| "#{path}:#{i + 1}: #{line.strip}" if line.match?(DECIDING) }
      end

      assert_empty(found, "the gallery decides again; fix: move each into GallerySurface (app/logical/gallery_surface.rb) and draw what it returns")
    end
  end
end
