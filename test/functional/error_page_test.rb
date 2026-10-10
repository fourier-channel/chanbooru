# frozen_string_literal: true

require "test_helper"

# THE ERROR PAGE, "Oh No!" (operator, 2026-10-10): what a signed-out viewer
# met was a bare "Error" heading top-left; the page is now a centred
# walk-through in the operator's words, with a pre-sized square for the
# picture a contest will choose, and the site's own error underneath.
class ErrorPageTest < ActionDispatch::IntegrationTest
  QUESTIONS = [
    "Have you registered?",
    "Are you already registered, but still here?",
    "Registered, logged in with fresh tokens, and yet, here you are again?",
    "Registered, newly logged in with a brand new set of tokens, and this page keeps popping up?",
    "So you're registered, session tokens fresh out the box, and absolutely sure something is supposed to be here?",
  ].freeze

  def assert_oh_no_page(details:)
    assert_select ".oh-no h1.oh-no-title", text: "Oh No!", count: 1
    # The square is there before any picture is: sized by the stylesheet, and
    # holding the placeholder until a picture is configured.
    assert_select ".oh-no .oh-no-art", count: 1
    assert_select ".oh-no .oh-no-art .oh-no-art-placeholder", count: 1
    assert_select ".oh-no .oh-no-art img", count: 0
    assert_select ".oh-no p.oh-no-intro", text: /\AYou have reached the error page\.\s+Which error, we cannot say for sure, because that's just the way computers work\.\s+The following flowchart of conditionals may help:\z/
    # role="list" because Safari/VoiceOver drops an unstyled list's semantics,
    # and the ordered flowchart is the point of the page (review, 2026-10-10).
    assert_equal(QUESTIONS, css_select(".oh-no ol.oh-no-flow[role='list'] > li.oh-no-step > h2.oh-no-question").map(&:text))
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

  context "With the contest picture configured" do
    should "draw that picture in the square, with its alt text" do
      Danbooru.config.stubs(:error_page_image_url).returns("https://example.com/oh-no.png")
      Danbooru.config.stubs(:error_page_image_alt).returns("A sad robot")
      get artist_path(999_999_999)

      assert_response 404
      assert_select ".oh-no .oh-no-art img.oh-no-art-image[src='https://example.com/oh-no.png'][alt='A sad robot']", count: 1
      # The placeholder stays under the picture (review, 2026-10-10): while it
      # loads the square shows the placeholder, not a page-coloured gap, and a
      # picture that fails hides itself rather than draw the browser's
      # broken-image symbol. Loaded, it tells the square to drop the placeholder.
      assert_select ".oh-no .oh-no-art .oh-no-art-placeholder[aria-hidden='true']", count: 1
      img = css_select(".oh-no .oh-no-art img.oh-no-art-image").first
      assert_match(/\bhidden\b/, img["onerror"])
      assert_match(/is-loaded/, img["onload"])
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
