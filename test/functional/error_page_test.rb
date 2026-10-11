# frozen_string_literal: true

require "test_helper"

# THE ERROR PAGE, "Oh No!" (operator, 2026-10-10): what a signed-out viewer
# met was a bare "Error" heading top-left; the page is now a centred
# walk-through in the operator's words, with a pre-sized square for a
# picture -- a booru post drawn from the landing console's list (2026-10-11)
# -- and the site's own error underneath.
class ErrorPageTest < ActionDispatch::IntegrationTest
  QUESTIONS = [
    "Have you registered?",
    "Are you already registered, but still here?",
    "Registered, logged in with fresh tokens, and yet, here you are again?",
    "Registered, newly logged in with a brand new set of tokens, and this page keeps popping up?",
    "So you're registered, session tokens fresh out the box, and absolutely sure something is supposed to be here?",
  ].freeze

  # Class level, not inside a context: shoulda runs each `should` through
  # instance_exec, so a `def` inside a context is not on the test object.
  def configure_pictures(*posts)
    setting = LandingSetting.current
    setting.error_page_post_ids = posts.map(&:id)
    setting.save!
  end

  # The post ids the error page drew over `times` loads, as `viewer` or signed out.
  def drawn_ids(times, viewer: nil)
    Array.new(times) do
      viewer ? get_auth(artist_path(999_999_999), viewer) : get(artist_path(999_999_999))
      href = css_select(".oh-no .oh-no-art a.oh-no-art-link").first&.attr("href")
      href && href[%r{\A/posts/(\d+)\z}, 1].to_i
    end
  end

  def maple_post(gallery, tags = "ep_landscape")
    tunnel = User.find_by(name: "tunnel") || create(:builder_user, name: "tunnel")
    post = as(tunnel) { create(:post, uploader: tunnel, tag_string: tags) }
    FourierPostCreator.create!(post: post, mxid: gallery.matrix_id, recorded_by: tunnel.id)
    post
  end

  # One post for each reason a signed-out visitor may not see a post, by name.
  def skipped_posts
    gallery = CreatorGallery.create!(matrix_id: "@hidden:41chan.net", slug: "hidden-ep", user: create(:user))
    tier = CreatorGroup.make!(gallery, name: "41chan_hidden_tier_1", tier: 1, by: gallery.user)
    hidden = maple_post(gallery)
    gallery.set_default_audience!("groups", by: gallery.user, group_ids: [tier.id])
    CreatorVisibility.forget!

    # Its own uploader: a deleted upload counts against its uploader's limit.
    deleter = create(:builder_user)
    deleted = as(deleter) { create(:post, uploader: deleter, tag_string: "ep_landscape") }
    deleted.update!(is_deleted: true)
    {
      "deleted" => deleted,
      "jailed (tag only, the delete half failed)" => as(@uploader) { create(:post, uploader: @uploader, tag_string: "ep_landscape #{Danbooru.config.troll_jail_tag}") },
      "creator-hidden" => hidden,
      "gated" => as(@uploader) { create(:post, uploader: @uploader, tag_string: "ep_landscape child") },
      "video" => as(@uploader) { create(:post, uploader: @uploader, tag_string: "ep_landscape", file_ext: "mp4") },
    }
  end

  def assert_oh_no_page(details:)
    assert_select ".oh-no h1.oh-no-title", text: "Oh No!", count: 1
    # The square is there before any picture is: sized by the stylesheet, and
    # holding the placeholder while no picture is drawn.
    assert_select ".oh-no .oh-no-art", count: 1
    assert_select ".oh-no .oh-no-art .oh-no-art-placeholder", count: 1
    assert_select ".oh-no .oh-no-art img", count: 0
    assert_select ".oh-no p.oh-no-intro", text: /\AYou have reached the error page\.\s+Which error, we cannot say for sure, because that's just the way computers work\.\s+The following flowchart of conditionals may help:\z/
    # role="list" because Safari/VoiceOver drops an unstyled list's semantics,
    # and the ordered flowchart is the point of the page (review, 2026-10-10).
    assert_equal(QUESTIONS, css_select(".oh-no ol.oh-no-flow[role='list'] > li.oh-no-step > details.oh-no-toggle > summary > h2.oh-no-question").map(&:text))
    # Each step is a toggle, collapsed by default (operator, 2026-10-10): the
    # questions read as the flowchart, and a reader opens the one that fits.
    assert_select ".oh-no details.oh-no-toggle", count: QUESTIONS.size
    assert_select ".oh-no details.oh-no-toggle[open]", count: 0
    assert_select ".oh-no details.oh-no-toggle > summary > .oh-no-triangle[aria-hidden='true']", count: QUESTIONS.size
    # The junk bin is the header's own purge icon, labelled, and not a button.
    assert_select ".oh-no .oh-no-bin[role='img'][aria-label='junk bin icon'] svg.purge-icon path", count: 1
    assert_select ".oh-no button", count: 0
    assert_select ".oh-no .oh-no-ui", text: "@Fourier:41chan.net"
    assert_select ".oh-no .oh-no-details p", text: details
  end

  context "A signed-out viewer" do
    should "get the Oh No! page from a members-only page refused by default-deny" do
      Danbooru.config.stubs(:anonymous_default_deny?).returns(true)
      get comments_path

      assert_response 404
      assert_oh_no_page(details: "Details: That record was not found.")
    end

    should "get the Oh No! page for a record that does not exist" do
      get artist_path(999_999_999)

      assert_response 404
      assert_oh_no_page(details: "Details: That record was not found.")
    end

    should "get the Oh No! page for a refusal, with its sign-in links in the details" do
      get news_updates_path

      assert_response 403
      assert_oh_no_page(details: /\ADetails:\s+You do not have permission to visit this page\.\s+Try logging in or\s+signing up\.\z/)
      assert_select ".oh-no-details a[href^='/login']", text: "logging in"
    end

    should "get the same purge bin the header's purge button draws" do
      get artist_path(999_999_999, preset: "modulation")

      assert_response 404
      header = css_select(".modnav-reset > button[data-act='purge'] svg path").first["d"]
      page = css_select(".oh-no .oh-no-bin svg path").first["d"]
      assert_equal(header, page)
    end
  end

  context "A post its creator hid, requested signed out" do
    # The page must not tell a hidden post from a missing one (CREATOR_VISIBILITY,
    # 2026-10-08: a hidden post answers as a missing post does); the details
    # line is the one place the error page says anything specific.
    setup do
      CreatorPrefixes.reset!
      CreatorTagRelease.reset_cache!
    end

    teardown do
      CreatorPrefixes.reset!
    end

    should "read exactly as a missing post does" do
      tunnel = create(:builder_user, name: "tunnel")
      gallery = CreatorGallery.create!(matrix_id: "@maple:41chan.net", slug: "maple-ep", user: create(:user))
      tier = CreatorGroup.make!(gallery, name: "41chan_maple_tier_1", tier: 1, by: gallery.user)
      post = as(tunnel) { create(:post, uploader: tunnel, tag_string: "eptest landscape") }
      FourierPostCreator.create!(post: post, mxid: "@maple:41chan.net", recorded_by: tunnel.id)
      gallery.set_default_audience!("groups", by: gallery.user, group_ids: [tier.id])
      CreatorVisibility.forget!

      get post_path(999_999_999)
      assert_response 404
      missing = css_select(".oh-no .oh-no-details").first.text.squish

      get post_path(post)
      assert_response 404
      assert_oh_no_page(details: "Details: That record was not found.")
      assert_equal(missing, css_select(".oh-no .oh-no-details").first.text.squish)
    end
  end

  context "A refusal raised with its own sentence" do
    should "show that sentence as the details line" do
      gallery = CreatorGallery.create!(slug: "alice", matrix_id: "@alice:41chan.net", title: "Alice")
      get_auth edit_creator_gallery_path(gallery), create(:user)

      assert_response 403
      assert_select ".oh-no h1.oh-no-title", text: "Oh No!"
      assert_select ".oh-no-details p", text: /\ADetails:\s+This page can only be edited by its owner/
    end
  end

  # THE PICTURES (operator, 2026-10-11): booru posts named on the landing
  # console, one drawn at random on each load. A post is drawn only if a
  # signed-out visitor may see it -- the hero band's own rule,
  # LandingShowcase.showable? -- AND the viewer in front of the page may; its
  # picture loads through the same door a slide's does (large_file_url), and a
  # signed-out viewer's draw is recorded as a slide's is, so the picture links
  # to a post page that opens for them.
  context "The error page's pictures" do
    setup do
      CreatorPrefixes.reset!
      CreatorTagRelease.reset_cache!
      @uploader = create(:builder_user) # no upload limit: these tests post many
      @ok = as(@uploader) { create(:post, uploader: @uploader, tag_string: "ep_landscape") }
    end

    teardown do
      CreatorPrefixes.reset!
    end

    should "draw a configured post, linked to its page, through the large-file door, named in its alt text" do
      artist = create(:artist_tag, name: "maple_drawer")
      post = as(@uploader) { create(:post, uploader: @uploader, tag_string: "ep_landscape maple_drawer") }
      configure_pictures(post)

      get artist_path(999_999_999)

      assert_response 404
      assert_select ".oh-no .oh-no-art a.oh-no-art-link[href='#{post_path(post)}'] img.oh-no-art-image", count: 1
      img = css_select(".oh-no .oh-no-art img.oh-no-art-image").first
      assert_equal post.large_file_url, img["src"]
      assert_equal "Post ##{post.id} by #{artist.name.tr("_", " ")}", img["alt"]
      # The placeholder stays under the picture (review, 2026-10-10): while it
      # loads the square shows the placeholder, not a page-coloured gap, and a
      # picture that fails hides itself rather than draw the browser's
      # broken-image symbol. Loaded, it tells the square to drop the placeholder.
      assert_select ".oh-no .oh-no-art .oh-no-art-placeholder[aria-hidden='true']", count: 1
      assert_match(/\bhidden\b/, img["onerror"])
      assert_match(/is-loaded/, img["onload"])
    end

    should "name a post with no artist tag by its number alone" do
      configure_pictures(@ok)
      get artist_path(999_999_999)

      assert_equal "Post ##{@ok.id}", css_select(".oh-no img.oh-no-art-image").first["alt"]
    end

    should "draw among the configured posts at random" do
      other = as(@uploader) { create(:post, uploader: @uploader, tag_string: "ep_landscape") }
      configure_pictures(@ok, other)

      assert_equal [@ok.id, other.id].sort, drawn_ids(30).uniq.sort
    end

    should "ask the hero band's own rule, not a copy of it" do
      configure_pictures(@ok)
      LandingShowcase.stubs(:showable?).returns(false)
      get artist_path(999_999_999)

      assert_select ".oh-no .oh-no-art img", count: 0
    end

    should "draw the placeholder when no post is configured" do
      get artist_path(999_999_999)

      assert_oh_no_page(details: "Details: That record was not found.")
    end

    should "never draw a post a signed-out visitor may not see, signed out or signed in" do
      skipped = skipped_posts
      skipped.each do |why, post|
        configure_pictures(post)
        reset!
        get artist_path(999_999_999)
        assert_select ".oh-no .oh-no-art img", { count: 0 }, "a #{why} post was drawn signed out"
        assert_select ".oh-no .oh-no-art .oh-no-art-placeholder", 1

        get_auth artist_path(999_999_999), create(:admin_user)
        assert_select ".oh-no .oh-no-art img", { count: 0 }, "a #{why} post was drawn to an admin"
      end

      # Mixed in with one that may be seen, only that one is ever drawn.
      configure_pictures(*skipped.values, @ok)
      reset!
      assert_equal [@ok.id], drawn_ids(12).uniq
    end

    should "fall through a post hidden from this viewer alone, to the placeholder or another post" do
      blocked = create(:user)
      gallery = CreatorGallery.create!(matrix_id: "@maple:41chan.net", slug: "maple-epb", user: create(:user))
      post = maple_post(gallery)
      CreatorUserRule.set!(gallery, blocked, rule: CreatorUserRule::BLOCK, by: gallery.user)
      CreatorVisibility.forget!
      configure_pictures(post)

      get_auth artist_path(999_999_999), blocked
      assert_select ".oh-no .oh-no-art img", count: 0
      assert_select ".oh-no .oh-no-art .oh-no-art-placeholder", 1

      # A block cannot stop a signed-out look at a public post (Q8), so
      # everyone else is drawn it.
      reset!
      get_auth artist_path(999_999_999), create(:user)
      assert_select ".oh-no .oh-no-art a[href='#{post_path(post)}'] img", count: 1

      configure_pictures(post, @ok)
      reset!
      assert_equal [@ok.id], drawn_ids(10, viewer: blocked).uniq
    end

    should "fall through a released banished post for an admin whose reveal is off" do
      Danbooru.config.stubs(:banished_tags).returns(["ep_banished_thing"])
      Danbooru.config.stubs(:banished_posts_need_reveal?).returns(true)
      # Released: live, still carrying its banished tag. Written past the
      # tag hooks, which would jail a post tagged with it.
      released = as(@uploader) { create(:post, uploader: @uploader, tag_string: "ep_landscape") }
      released.update_columns(tag_string: "ep_landscape ep_banished_thing") # rubocop:disable Rails/SkipsModelValidations -- past the tag hooks, as a release leaves it
      configure_pictures(released)

      get_auth artist_path(999_999_999), create(:admin_user)
      assert_select ".oh-no .oh-no-art img", count: 0

      # The hero band's rule shows a released post to a signed-out visitor,
      # so the error page does too -- this is the admin's own withholding.
      reset!
      get artist_path(999_999_999)
      assert_select ".oh-no .oh-no-art a[href='#{post_path(released)}'] img", count: 1
    end

    should "record a signed-out viewer's draw, so the picture's post page opens for them" do
      Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
      Danbooru.config.stubs(:anonymous_default_deny?).returns(true)
      MembersOnly.stubs(:anonymous_newest_ids).returns(Set.new)
      configure_pictures(@ok)

      # Not shown yet, so not open: the record is what opens it.
      get post_path(@ok)
      assert_response 404

      get artist_path(999_999_999)
      assert_select ".oh-no .oh-no-art a[href='#{post_path(@ok)}'] img", count: 1

      get post_path(@ok)
      assert_response :success
    end

    should "draw a console save at once, without waiting for the cache" do
      Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
      other = as(@uploader) { create(:post, uploader: @uploader, tag_string: "ep_landscape") }
      configure_pictures(@ok)
      assert_equal [@ok.id], drawn_ids(3).uniq

      put_auth admin_landing_setting_path, create(:admin_user), params: { landing_setting: { error_page_post_ids_text: other.id.to_s }}
      assert_redirected_to admin_landing_setting_path
      reset!

      assert_equal [other.id], drawn_ids(3).uniq
    end

    should "never draw a post jailed after the list was cached" do
      Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
      configure_pictures(@ok)
      assert_equal [@ok.id], drawn_ids(2).uniq

      @ok.update!(is_deleted: true) # jailed means deleted
      get artist_path(999_999_999)
      assert_select ".oh-no .oh-no-art img", count: 0
      assert_select ".oh-no .oh-no-art .oh-no-art-placeholder", 1
    end

    should "draw the placeholder and log, never raise, when the pick fails" do
      configure_pictures(@ok)
      LandingSetting.stubs(:current).raises(ActiveRecord::StatementInvalid, "PG::ConnectionBad: the database is down")
      DanbooruLogger.stubs(:log)
      DanbooruLogger.expects(:log).with { |e, **params| e.is_a?(ActiveRecord::StatementInvalid) && params[:context] == "error_page_picture" }.once

      get artist_path(999_999_999)

      assert_response 404
      assert_oh_no_page(details: "Details: That record was not found.")
    end

    should "not make the page cacheable by anyone else" do
      configure_pictures(@ok)
      get artist_path(999_999_999)

      assert_select ".oh-no .oh-no-art img", count: 1
      assert_no_match(/public/, response.headers["Cache-Control"].to_s)
    end
  end

  context "A JSON error" do
    should "be unchanged" do
      get artist_path(999_999_999, format: :json)

      assert_response 404
      assert_equal("application/json", response.media_type)
      assert_equal(false, response.parsed_body["success"])
      assert_equal("ActiveRecord::RecordNotFound", response.parsed_body["error"])
      assert_equal("That record was not found.", response.parsed_body["message"])
      assert_no_match(/Oh No!/, response.body)
    end
  end
end
