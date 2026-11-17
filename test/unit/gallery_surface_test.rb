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
