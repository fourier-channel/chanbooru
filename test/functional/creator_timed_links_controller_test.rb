# frozen_string_literal: true

require "test_helper"

# TIMED LINKS ON THE EDIT SCREEN (CREATOR_REACH sec 2): PATCH creators/:slug
# with timed_link=create|end, and the Timed links panel on the editor.
#
# Asked here: only the panel's writer (the verified owner signed in as the
# page's account, or an admin) reaches sampling at all; a post that is not the
# creator's is refused before anything is sent; End now sends the delete; and
# the editor still draws, saying why, when sampling is off, down or unset.
class CreatorTimedLinksControllerTest < ActionDispatch::IntegrationTest
  include TimedLinksHelper

  MAPLE = { "X-Fourier-Identity" => "@maple:41chan.net" }.freeze

  def maple_post
    post = as(@tunnel) { create(:post, uploader: @tunnel, md5: SecureRandom.hex(16)) }
    FourierPostCreator.create!(post: post, mxid: "@maple:41chan.net", recorded_by: @tunnel.id)
    post
  end

  def write(user, headers: MAPLE, **params)
    put_auth creator_gallery_path(@gallery), user, params: params, headers: headers
  end

  def back_to_panel
    assert_redirected_to edit_creator_gallery_path(@gallery, anchor: "modcreator-box-timed-links")
  end

  setup do
    CreatorPrefixes.reset!
    travel_to Time.zone.parse("2026-11-08 12:00")
    @tunnel = create(:builder_user, name: "tunnel")
    @maple = create(:user)
    @gallery = CreatorGallery.create!(slug: "maple", matrix_id: "@maple:41chan.net", title: "Maple", user: @maple)
    @http = FakeSamplingHttp.new
    # Built before the stub: inside .returns(...) the call to new would hit the stub.
    links = timed_links(@gallery, @http)
    CreatorTimedLinks.stubs(:new).returns(links)
  end

  context "making a link" do
    should "send the owner's posts in their order and say where the link is and until when" do
      a = maple_post
      b = maple_post
      @http.answer(listing([], max_live: 5, max_days: 30))
      @http.answer({ ok: true, link: link_row(hash: "f" * 32, title: "October", posts: 2) })

      write(@maple, timed_link: "create", post_ids: "#{b.id}, #{a.id} #{b.id}", title: "October", ends_on: "2026-11-30")
      back_to_panel
      assert_equal "Made: https://sample.example.net/p/#{"f" * 32} -- it shows 2 posts until the end of 2026-11-30.", flash[:notice]
      assert_equal %i[get post], @http.calls.pluck(:method)
      body = @http.calls.last[:options][:json]
      assert_equal [b.id, a.id], body[:posts].pluck(:id)
      assert_equal @gallery.id.to_s, body[:owner]
    end

    should "refuse a post that is not the creator's, before asking sampling" do
      theirs = maple_post
      other = create(:post, md5: SecureRandom.hex(16))
      write(@maple, timed_link: "create", post_ids: "#{theirs.id} #{other.id}", ends_on: "2026-11-30")
      back_to_panel
      assert_match(/Post ##{other.id} is not one of your posts/, flash[:notice])
      assert_empty @http.calls
    end

    should "refuse a missing end date and too many posts, before asking sampling" do
      post = maple_post
      write(@maple, timed_link: "create", post_ids: post.id.to_s, ends_on: "")
      assert_equal "Pick the last day the link should work.", flash[:notice]
      write(@maple, timed_link: "create", post_ids: (1..25).to_a.join(" "), ends_on: "2026-11-30")
      assert_match(/at most 24 posts; you listed 25/, flash[:notice])
      assert_empty @http.calls
    end

    should "tell the creator a failure plainly and keep the reason for the log" do
      post = maple_post
      @http.answer({ error: "no" }, status: 401)
      write(@maple, timed_link: "create", post_ids: post.id.to_s, ends_on: "2026-11-30")
      back_to_panel
      assert_match(/link service did not answer as it should/, flash[:notice])
      assert_no_match(/FS_CREATOR_LINK_KEY|DANBOORU_/, flash[:notice])
    end
  end

  context "who may write" do
    should "refuse everyone but the page's writer, and ask sampling nothing" do
      post = maple_post
      stranger = create(:user)
      moderator = create(:moderator_user)
      [[stranger, {}], [moderator, {}], [stranger, MAPLE]].each do |user, headers|
        write(user, headers: headers, timed_link: "create", post_ids: post.id.to_s, ends_on: "2026-11-30")
        assert_response 403
        write(user, headers: headers, timed_link: "end", hash: "a" * 32)
        assert_response 403
      end
      assert_empty @http.calls
    end

    should "refuse an unknown act" do
      write(@maple, timed_link: "extend", hash: "a" * 32)
      assert_response 400
      assert_empty @http.calls
    end
  end

  context "End now" do
    should "end the link at sampling" do
      @http.answer({ ok: true, ended: "a" * 32 })
      write(@maple, timed_link: "end", hash: "a" * 32)
      back_to_panel
      assert_equal "Ended. That address shows nothing from now on.", flash[:notice]
      assert_equal [:delete, "#{BASE}/api/publish"], [@http.calls.sole[:method], @http.calls.sole[:url]]
    end

    should "say a link already gone is gone" do
      @http.answer({ error: "not one of this creator's live links" }, status: 404)
      write(@maple, timed_link: "end", hash: "a" * 32)
      assert_match(/already ended/, flash[:notice])
    end
  end

  context "the Timed links panel" do
    should "list the live links with their addresses and the count against the limit" do
      @http.answer(listing([link_row(hash: "c" * 32, title: "October", posts: 3)], max_live: 5, max_days: 30))
      get_auth edit_creator_gallery_path(@gallery), @maple, headers: MAPLE
      assert_response :success
      assert_select ".modcreator-timed-count", text: "1 of 5 live links"
      assert_select "input.modcreator-timed-url[value=?]", "https://sample.example.net/p/#{"c" * 32}"
      assert_select "form.modcreator-timed-form"
      assert_select "input[name=ends_on][max=?]", "2026-12-07"
    end

    should "still draw the editor when sampling does not answer, and say so" do
      @http.answer("", status: 598)
      get_auth edit_creator_gallery_path(@gallery), @maple, headers: MAPLE
      assert_response :success
      assert_select ".modcreator-timed-problem", text: /cannot be shown right now/
      assert_select "form.modcreator-timed-form", count: 0
    end

    should "say timed links are not switched on when the booru has no key" do
      CreatorTimedLinks.unstub(:new)
      unset = CreatorTimedLinks.new(@gallery, url: nil, key: nil, http: @http)
      CreatorTimedLinks.stubs(:new).returns(unset)
      get_auth edit_creator_gallery_path(@gallery), @maple, headers: MAPLE
      assert_response :success
      assert_select ".modcreator-timed-problem", text: /not switched on yet/
      assert_empty @http.calls
    end
  end
end
