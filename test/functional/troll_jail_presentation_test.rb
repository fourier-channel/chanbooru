# frozen_string_literal: true

require "test_helper"

# What a jailed or deleted post looks like once someone allowed to see it opens it.
#
# Three things that were each invisible for a different reason:
#
#   1. The jail tag. fourier-sampling applies it with a plain tag_string PUT, so
#      it has no FourierTagSource row -- and the Modulation tag panel reads only
#      that table, so the tag was on 38 production posts and drawn on none of
#      them.
#   2. Why the post was deleted. The reason is the operator's own words on the
#      deletion flag ("troll jail: shock") and the notice said only "This post
#      was deleted."
#   3. The picture itself. Opening a deleted post to find out what was removed
#      should not put the image on screen as a side effect of arriving.
class TrollJailPresentationTest < ActionDispatch::IntegrationTest
  JAIL = "troll_jail"

  context "A jailed post" do
    setup do
      # Admin: this fork 404s a deleted post for everyone below that level, so an
      # admin is the only viewer who can reach one at all.
      @admin = create(:admin_user)
      @uploader = create(:user)
      @post = create(:post, tag_string: "landscape", uploader: @uploader)
    end

    should "show the jail tag even though nothing recorded its provenance" do
      FourierTagSource.record_partition!(@post, { "auto" => ["landscape"] }, @uploader)
      @post.update!(tag_string: "landscape #{JAIL}")

      buckets = FourierTagSource.for_viewer(@post.reload, @admin)

      assert_includes buckets[:auto], "landscape"
      assert_includes buckets[:unsourced], JAIL
    end

    should "carry a jail notice on the post view" do
      @post.update!(tag_string: "landscape #{JAIL}")

      get_auth post_path(@post), @admin, params: { preset: "modulation" }

      assert_response :success
      payload = modulation_payload(response.body)
      assert_includes payload["notices"].map { |n| n["kind"] }, "jailed"
      assert_includes payload["tags"]["unsourced"], JAIL
    end

    should "not carry one when the post is not jailed" do
      get_auth post_path(@post), @admin, params: { preset: "modulation" }

      assert_response :success
      refute_includes modulation_payload(response.body)["notices"].map { |n| n["kind"] }, "jailed"
    end
  end

  context "A deleted post" do
    setup do
      @admin = create(:admin_user)
      @post = create(:post, tag_string: "landscape")
      @post.delete!("troll jail: shock", user: @admin)
    end

    should "state why it was deleted, in the words that were recorded" do
      get_auth post_path(@post), @admin, params: { preset: "modulation" }

      assert_response :success
      deleted = modulation_payload(response.body)["notices"].find { |n| n["kind"] == "deleted" }

      assert_not_nil deleted
      assert_includes deleted["text"], "troll jail: shock"
    end

    should "hand the client the status the spoiler is keyed on" do
      # The veil itself is applied client-side, over media the page has already
      # been given -- it is a viewing decision, not a gate. What the server owes
      # is the fact the client keys on.
      get_auth post_path(@post), @admin, params: { preset: "modulation" }

      assert_response :success
      assert_equal "deleted", modulation_payload(response.body)["status"]
    end

    should "veil its thumbnail in the gallery, for a viewer who asked to see it" do
      @admin.update!(show_deleted_posts: true)
      visible = create(:post, tag_string: "landscape")

      get_auth posts_path, @admin, params: { preset: "modulation", tags: "landscape" }

      assert_response :success
      assert_select ".modgal-card--spoiler[data-id=?]", @post.id.to_s, 1
      assert_select ".modgal-card--spoiler[data-id=?]", visible.id.to_s, 0
    end
  end

  private

  def modulation_payload(body)
    JSON.parse(body[/data-payload="([^"]*)"/, 1].then { |raw| CGI.unescapeHTML(raw) })
  end
end
