# frozen_string_literal: true

require "test_helper"

# GATE 3 FOR POSTS PLACED ON A PUBLIC GALLERY (operator, 2026-11-01):
# "Images a user places on their public gallery is considered a whitelist for
# those posts that lets them through Gate 3 (specifically). Just as with all
# other signed-out content, the authorizations are temporary."
#
# A view of a creator's page that is not private, by anyone, records the
# posts its creator PLACED there -- the hero picks, each miniband's posts, the
# banner and the Tuner's pictures, as stored -- for the hour or two the shown
# record keeps (MembersOnly.remember_placed). While fresh, a Matrix post among
# them passes Gate 3 for every viewer, signed in or out (operator, 2026-11-01:
# "an unlock for gate 3 on that specific view surface and not scoped to any
# given user"), and nothing else: every other gate still hides it, and a post
# whose every placement was redacted (no rooms) stays hidden.
class CreatorGalleryGate3GrantTest < ActionDispatch::IntegrationTest
  include TagQuarantineTestHelper

  PREFIXES = <<~YAML
    editors: [tunnel]
    prefixes:
      - {prefix: aichan_, provenance: Discord, target_kind: server, target: AIChan, scope: x, visible_to: admins}
  YAML

  setup do
    @dir = Dir.mktmpdir("gate3-grant")
    File.write(File.join(@dir, "creator_prefixes.yml"), PREFIXES)
    @was = ENV.fetch("FOURIER_CREATOR_PREFIXES", nil)
    ENV["FOURIER_CREATOR_PREFIXES"] = File.join(@dir, "creator_prefixes.yml")
    CreatorPrefixes.reset!

    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    Danbooru.config.stubs(:anonymous_default_deny?).returns(true)
    Danbooru.config.stubs(:gate3_matrix_posts_enforced?).returns(true)
    @tunnel = create(:contributor_user)
    @admin = create(:admin_user)
    @owner = create(:user)
    @gallery = CreatorGallery.create!(slug: "rain", matrix_id: "@rain:41chan.net", user: @owner)
    room = MatrixRoom.intern!(["!art:41chan.net"]).fetch("!art:41chan.net")
    make = lambda do |tags, rooms: [room]|
      post = as(@tunnel) { create(:post, uploader: @tunnel, md5: SecureRandom.hex(16), tag_string: tags, rating: "g") }
      FourierPostCreator.create!(post: post, mxid: @gallery.matrix_id, recorded_by: @tunnel.id)
      post.update_columns(room_ids: rooms) # rubocop:disable Rails/SkipsModelValidations -- PostMxc's answer, as gate3_matrix_posts_test places one
      post
    end

    @hero = make.call("night")
    @plain = make.call("night", rooms: [MatrixViewerRooms::NOT_MATRIX])
    @redacted = make.call("night", rooms: [])
    @mini = make.call("snow")
    @banner = make.call("dawn")
    @picture = make.call("dusk")
    @loose = make.call("night")
    @gallery.update!(settings: { "hero" => { "tags" => %w[night] }, "banner" => { "post_id" => @banner.id }, "layout" => "1-2",
                                 "minis" => [{ "tag" => "snow" }], "tuner" => { "enabled" => true }})
    [@hero, @plain, @redacted].each_with_index { |post, i| @gallery.creator_gallery_posts.create!(band: "hero", post: post, position: i) }
    @gallery.creator_gallery_posts.create!(band: "mini1", post: @mini, position: 0)
    @gallery.creator_gallery_harmonics.create!(site: "civitai", url: "https://civitai.com/user/Rain", title: "Rain", places: CreatorGalleryHarmonic::CONFIG["presets"].first.last,
                                               background_post_id: @picture.id, focus_x: 50, focus_y: 50, zoom: 100, shade: 45)
    create_list(:post, 21) # rubocop:disable FactoryBot/ExcessiveCreateList -- off the gallery's first page, so only the draw can grant them
    CreatorVisibility.forget!
  end

  teardown do
    ENV["FOURIER_CREATOR_PREFIXES"] = @was
    CreatorPrefixes.reset!
    FileUtils.rm_rf(@dir)
  end

  def view(user = nil, headers: {})
    user ? get_auth(creator_gallery_path(@gallery), user, headers: headers) : get(creator_gallery_path(@gallery), headers: headers)
    assert_response :success
  end

  # Drawn for a signed-out viewer: the draw grants exactly what it drew
  # (CreatorGalleriesController#grant_anonymous_draw).
  def drawn?(post) = MembersOnly.anonymous_shown_post?(post.id, safe_mode: false)

  # On the page as rendered: a slide carries its post's page, the banner and
  # a harmonic's picture their post's id as a blacklist target.
  def rendered?(post) = response.body.include?("/posts/#{post.id}&quot;") || response.body.include?("data-id=\"#{post.id}\"")

  # What a signed-out viewer's own search finds among `posts`, and what the
  # post's own rule hides; the two must agree.
  def found_signed_out(posts)
    CreatorVisibility.forget!
    anonymous = User.anonymous
    CurrentUser.set(user: anonymous, request: ActionDispatch::TestRequest.create, safe_mode: false) do
      found = PostQuery.normalize("id:#{posts.map(&:id).join(",")}", current_user: anonymous).with_implicit_metatags.posts.pluck(:id).sort
      visible = posts.reject { |post| post.reload.hidden_from?(anonymous) }.map(&:id).sort
      assert_equal visible, found, "the search and Post#hidden_from? must agree"
      found
    end
  end

  def md5_ask(posts)
    get posts_path(format: :json), params: { tags: "md5:#{posts.map(&:md5).join(",")}", only: "md5,is_deleted,source", limit: posts.size }
    assert_response :success
    response.parsed_body.pluck("md5")
  end

  context "a public page viewed signed out" do
    should "draw every post placed on it, the Matrix posts among them, but a redacted one" do
      view
      [@hero, @plain, @mini, @banner, @picture].each do |post|
        assert(drawn?(post), "placed post ##{post.id} was not drawn")
        assert(rendered?(post), "placed post ##{post.id} is not on the page")
      end
      assert_not(drawn?(@redacted), "a post with no rooms left was drawn")
      assert_not(rendered?(@redacted))
    end

    should "let the posts it placed through Gate 3 alone, for a signed-out viewer, until the record expires" do
      everyone = [@hero, @plain, @redacted, @mini, @banner, @picture, @loose]
      assert_equal [@plain.id], found_signed_out(everyone), "fixture: Gate 3 hides every Matrix post signed out"

      view
      assert_equal [@hero, @plain, @mini, @banner, @picture].map(&:id).sort, found_signed_out(everyone)

      travel(2.hours + 1.minute) do
        assert_equal [@plain.id], found_signed_out(everyone), "the grant outlived the shown record"
      end
    end

    should "open a placed post's page and answer its md5, and neither for a Matrix post not placed" do
      view
      # Remembered as shown too, so what keeps them out below is Gate 3.
      MembersOnly.remember_shown_to_anonymous([@loose.id, @redacted.id], safe_mode: false)
      get post_path(@hero)
      assert_response :success
      [@loose, @redacted].each do |post|
        get post_path(post)
        assert_response 404
      end
      assert_equal [@hero.md5], md5_ask([@hero, @loose, @redacted])
    end

    should "still hide a placed Matrix post that any other gate hides" do
      # Production's rule, not the test environment's permissive one
      # (danbooru_local_config.rb, deleted_post_visibility_level).
      Danbooru.config.stubs(:deleted_post_visibility_level).returns(User::Levels::ADMIN)
      jailed = as(@tunnel) { create(:post, uploader: @tunnel, md5: SecureRandom.hex(16), tag_string: "night troll_jail", rating: "g") }
      deleted = as(@tunnel) { create(:post, uploader: @tunnel, md5: SecureRandom.hex(16), tag_string: "night", rating: "g") }
      flagged = as(@tunnel) { create(:post, uploader: @tunnel, md5: SecureRandom.hex(16), tag_string: "night g3_flagged", rating: "g") }
      # A creator tag is the posting service's or an admin's to add.
      prefixed = as(@admin) { create(:post, uploader: @tunnel, md5: SecureRandom.hex(16), tag_string: "night aichan_rain", rating: "g") }
      others = [jailed, deleted, flagged, prefixed]
      room_ids = @hero.room_ids
      others.each_with_index do |post, i|
        FourierPostCreator.create!(post: post, mxid: @gallery.matrix_id, recorded_by: @tunnel.id)
        post.update_columns(room_ids: room_ids) # rubocop:disable Rails/SkipsModelValidations -- PostMxc's answer
        @gallery.creator_gallery_posts.create!(band: "hero", post: post, position: 10 + i)
      end
      jailed.delete!("troll jail: shock", user: @admin)
      deleted.delete!("ordinary deletion", user: @admin)
      flag_tags!("g3_flagged")
      CreatorVisibility.forget!

      view
      # The page's own rules refuse the jailed and the deleted one, so their
      # placements grant nothing; the rest are recorded, and another gate
      # must hide them.
      assert_equal [flagged, prefixed].map(&:id).sort, (others.map(&:id) & MembersOnly.placed_ids.to_a).sort
      others.each { |post| assert_not(drawn?(post), "post ##{post.id} was drawn") }
      assert_empty found_signed_out(others)
      MembersOnly.remember_shown_to_anonymous(others.map(&:id), safe_mode: false)
      others.each do |post|
        get post_path(post)
        assert_response 404
      end
      assert_empty md5_ask(others)
    end

    should "record only the placed posts the page itself would draw, Gate 3 aside" do
      # Placed while the creator's, then another creator's: the page refuses
      # it ("it is not one of your posts"), so its placement grants nothing.
      foreign = as(@tunnel) { create(:post, uploader: @tunnel, md5: SecureRandom.hex(16), tag_string: "night", rating: "g") }
      FourierPostCreator.create!(post: foreign, mxid: "@someone_else:41chan.net", recorded_by: @tunnel.id)
      # The creator's own, but no longer fitting the hero band's tags.
      misfit = as(@tunnel) { create(:post, uploader: @tunnel, md5: SecureRandom.hex(16), tag_string: "rain", rating: "g") }
      FourierPostCreator.create!(post: misfit, mxid: @gallery.matrix_id, recorded_by: @tunnel.id)
      [foreign, misfit].each_with_index do |post, i|
        post.update_columns(room_ids: @hero.room_ids) # rubocop:disable Rails/SkipsModelValidations -- PostMxc's answer
        @gallery.creator_gallery_posts.create!(band: "hero", post: post, position: 10 + i)
      end
      CreatorVisibility.forget!

      view
      assert(rendered?(@hero), "fixture: the creator's own placed post is on the page")
      [foreign, misfit].each do |post|
        assert_not(rendered?(post), "post ##{post.id} is on the page")
        assert_not_includes MembersOnly.placed_ids, post.id, "post ##{post.id}, which the page refuses, was recorded as placed"
      end
      assert_empty found_signed_out([foreign, misfit])
    end

    should "draw its placed posts to a signed-in viewer outside the rooms too" do
      member = create(:user)
      view(member)
      assert(rendered?(@hero), "a member outside the rooms was not drawn the placed Matrix post")
      assert_not(rendered?(@redacted))
      CreatorVisibility.forget!
      assert_not(CurrentUser.set(user: member, request: ActionDispatch::TestRequest.create) { @hero.reload.hidden_from?(member) })

      reset!
      view(headers: { "X-Fourier-Identity" => "@bob:41chan.net" })
      assert(rendered?(@hero), "a verified Matrix viewer outside the rooms was not drawn the placed Matrix post")
    end
  end

  context "a public page viewed signed in" do
    should "record its placed posts for everyone, and answer the image door's md5 ask for them" do
      member = create(:user)
      view(member)
      placed = MembersOnly.placed_ids
      [@hero, @mini, @banner, @picture].each { |post| assert_includes placed, post.id }
      [@plain, @loose].each { |post| assert_not_includes placed, post.id }

      # The Matrix door asks the booru as nobody for a token holder outside
      # the rooms, so the md5 ask answers the placed posts whoever viewed the
      # page; never one with no rooms left, nor one not placed.
      reset!
      assert_equal [@hero.md5], md5_ask([@hero, @loose, @redacted])
      # A signed-in view draws nothing for a signed-out viewer: the post's page
      # opens to one only when a signed-out view drew it (gate 10).
      assert_not(drawn?(@hero))
      get post_path(@hero)
      assert_response 404
    end
  end

  context "a private page" do
    setup { @gallery.update!(page_private: true) }

    should "record nothing, so its Matrix posts stay hidden" do
      view(@owner)
      view
      assert_empty MembersOnly.placed_ids
      assert_not(drawn?(@banner), "a private page's Matrix banner was drawn")
      assert_equal [@plain.id], found_signed_out([@hero, @plain, @mini, @banner, @picture])
    end
  end
end
