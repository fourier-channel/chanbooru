# frozen_string_literal: true

require "test_helper"

# PostStripSurface decides the post strips on Modulation's subject pages (an
# artist's, a wiki page's, the popular page) for the viewer it is handed. What
# each viewer is offered is pinned by the parity and privacy recordings; this
# pins the shape: exactly the posts upstream's gallery would draw
# (PostPreviewComponent.drawable?), never a COUNT, and the gallery's own card
# data, so a blocklist hides a strip card exactly as it hides the gallery's.
class PostStripSurfaceTest < ActiveSupport::TestCase
  include TagQuarantineTestHelper

  COMPONENTS = %w[
    app/interfaces/modulation/components/modulation_post_strip_component.rb
    app/interfaces/modulation/components/modulation_post_strip_component/modulation_post_strip_component.html.erb
    app/interfaces/modulation/components/modulation_subject_header_component.rb
    app/interfaces/modulation/components/modulation_subject_header_component/modulation_subject_header_component.html.erb
    app/interfaces/modulation/components/modulation_panel_component.rb
    app/interfaces/modulation/components/modulation_panel_component/modulation_panel_component.html.erb
  ].freeze
  # GallerySurfaceTest::DECIDING, the same rule for the same reason; repeated
  # because a test file cannot rely on another being loaded.
  DECIDING = /\b(?:CurrentUser|current_user|viewer)\b|\bMembersOnly\b|Policy\b|\bpolicy\(|\.visible\?|\.(?:pending|count|where|find_by|pluck)\b|\b(?:ModulationSetting|SessionObservation|TagQuarantine|TagBanishment|FourierTagSource|CharacterClaim)\b/

  def strip_for(viewer, relation = Post.where(id: @posts.map(&:id)).order(id: :desc), **options)
    PostStripSurface.new(relation: relation, viewer: viewer, query: "pstrip", **options)
  end

  context "PostStripSurface" do
    setup do
      @owner = create(:owner_user)
      @member = create(:user)
      as(@owner) do
        @shown = create(:post, tag_string: "pstrip")
        @deleted = create(:post, tag_string: "pstrip", is_deleted: true)
        @banned = create(:post, tag_string: "pstrip", is_banned: true)
        @banished = create(:post, tag_string: "pstrip pstrip_banished")
      end
      @posts = [@shown, @deleted, @banned, @banished]
      # Withholding is off under test unless stubbed on (TagBanishment,
      # banished_post_visibility_test).
      Danbooru.config.stubs(:banished_posts_withheld?).returns(true)
      banish_tags!("pstrip_banished")
    end

    should "draw exactly what upstream's gallery would draw for the viewer: no invisible, deleted or banished post" do
      drawn = strip_for(@member).posts

      assert_equal([@shown.id], drawn.map(&:id), "the strip drew a post upstream omits for this viewer; fix: PostStripSurface#posts selects through PostPreviewComponent.drawable?")
      @posts.each do |post|
        assert_equal(PostPreviewComponent.drawable?(post, @member), drawn.include?(post), "post ##{post.id}: the strip and upstream's gallery disagree")
      end
    end

    should "draw a banned post for an Approver, and keep the relation's order" do
      approver = create(:approver)
      drawn = strip_for(approver).posts.map(&:id)

      assert_includes(drawn, @banned.id, "an Approver is drawn banned posts upstream's gallery draws them")
      assert_equal(drawn.sort.reverse, drawn, "the strip reordered the relation; fix: PostStripSurface#posts selects in place")
    end

    # Gate 1 (Post#hidden_as_gated?, inside hidden_beyond_deletion?): the post
    # does not exist for the viewer, so the strip omits it rather than draw a
    # gated card that would name its id.
    should "omit a level-gated post" do
      Post.any_instance.stubs(:hidden_as_gated?).returns(true)

      assert_empty(strip_for(@member).posts, "a level-gated post reached the strip; fix: PostStripSurface#posts selects through PostPreviewComponent.drawable?")
    end

    # Safe mode (Post#safeblocked?): listed but not visible. Upstream's gallery
    # omits it (PostPreviewComponent#render?), and so does the strip.
    should "omit a post safe mode hides" do
      Post.any_instance.stubs(:safeblocked?).returns(true)

      assert_equal(true, PostPreviewComponent.listed?(@shown, @member), "fixture: the post is listed")
      assert_empty(strip_for(@member).posts, "a post safe mode hides reached the strip; fix: PostStripSurface#posts selects through drawable?, not listed?")
    end

    should "draw a deleted post only when the page asks for deleted posts" do
      assert_includes(strip_for(@member, show_deleted: true).posts.map(&:id), @deleted.id)
    end

    should "take the array posts_with_timeout answers as well as a relation" do
      array = Post.where(id: @posts.map(&:id)).order(id: :desc).to_a

      assert_equal([@shown.id], strip_for(@member, array).posts.map(&:id))
      assert(strip_for(@member, array).posts.first.association(:media_asset).loaded?, "the array's media assets were not preloaded; fix: PostStripSurface#loaded preloads :media_asset")
    end

    should "be empty when nothing is drawable" do
      assert(strip_for(@member, Post.where(id: @banned.id)).empty?)
    end

    should "never count" do
      surface = strip_for(@member)
      sql = []
      callback = ->(*, payload) { sql << payload[:sql] }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        surface.posts.each { |post| surface.card_data(post) && surface.post_link(post) && surface.thumb_for(post) && surface.artist_for(post) }
      end

      assert_not_empty(sql, "fixture: the strip ran its queries inside the subscription")
      assert_empty(sql.grep(/\bCOUNT\(/i), "the strip counted; fix: PostStripSurface draws the relation it is handed and never pages or counts it")
    end

    should "carry the same data-tags as the gallery's card for the same post" do
      request = ActionDispatch::TestRequest.create
      gallery = GallerySurface.new(post_set: PostSets::Post.new("pstrip", nil, nil, user: @member, window: :page), viewer: @member, request: request, session: request.session)
      gallery_post = gallery.post_set.posts.find { |post| post.id == @shown.id }
      strip = strip_for(@member)
      strip_post = strip.posts.find { |post| post.id == @shown.id }

      assert_not_nil(gallery_post, "fixture: the gallery draws the shown post")
      assert_not_nil(strip_post, "fixture: the strip draws the shown post")
      assert_equal(gallery.card_data(gallery_post)["data-tags"], strip.card_data(strip_post)["data-tags"], "the strip's blocklist projection differs from the gallery's; fix: both take card_data from PostCards")
      assert_equal(gallery.card_data(gallery_post).except("data-key"), strip.card_data(strip_post))
    end
  end

  context "The Modulation strip, header and panel components" do
    should "decide nothing: no viewer, policy or query of their own" do
      found = COMPONENTS.flat_map do |path|
        source = Rails.root.join(path).read
        source = path.end_with?(".erb") ? source.gsub(/<%#.*?%>/m) { |c| "\n" * c.count("\n") } : source.gsub(/^\s*#.*$/, "")
        source.lines.each_with_index.filter_map { |line, i| "#{path}:#{i + 1}: #{line.strip}" if line.match?(DECIDING) }
      end

      assert_empty(found, "a strip component decides; fix: move each into PostStripSurface (app/logical/post_strip_surface.rb) or the caller")
    end
  end
end
