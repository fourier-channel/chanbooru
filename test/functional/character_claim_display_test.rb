# frozen_string_literal: true

require "test_helper"

# Where a claimed original character shows whose it is (OC ownership, ruled
# 2026-10-11): "by <creator>" beside the character pill on the post page, a
# line on the wiki page and the search excerpt, and a Characters list on the
# creator's gallery. A signed-out visitor is told nothing new: they see the
# creator's @slug, which is already in the tag's name, linked to the
# creator's page, which every visitor may open (operator, 2026-10-23).
class CharacterClaimDisplayTest < ActionDispatch::IntegrationTest
  def sql_during(&)
    statements = []
    counter = ->(*, payload) { statements << payload[:sql] unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &)
    statements
  end

  def payload(post, viewer)
    as(viewer) { ModulationPostComponent.new(post: post, viewer: viewer).payload }
  end

  setup do
    CreatorPrefixes.reset!
    @saber = create(:user)
    @member = create(:user)
    @admin = create(:admin_user)
    @gallery = CreatorGallery.create!(slug: "saber", matrix_id: "@saber:41chan.net", title: "Saber Studio", user: @saber)
    CharacterClaim.prepare(@gallery, @saber, "maple").first.file!
    @post = as(@member) { create(:post, tag_string: "maple_(saber) hilda_(pokemon) char:hilda_(pokemon) landscape") }
    @plain = as(@member) { create(:post, tag_string: "landscape") }
  end

  context "the post page payload" do
    should "name the creator of a claimed character pill, and only that one" do
      owners = payload(@post, @member)[:oc_owners]

      assert_equal({ "maple_(saber)" => { name: "Saber Studio", href: "/creators/saber", contact: false }}, owners)
    end

    should "ask nothing with no character tags, and one query with them" do
      component = ModulationPostComponent.new(post: @plain, viewer: @member)
      component.category_tags
      assert_empty(sql_during { assert_equal({}, component.oc_owners) }.grep(/character_claims/))

      component = ModulationPostComponent.new(post: @post, viewer: @member)
      component.category_tags
      assert_equal(1, sql_during { component.oc_owners }.size)
    end

    should "give a signed-out visitor the @slug, linked to the gallery, promoted or not" do
      assert_equal({ "maple_(saber)" => { name: "@saber", href: "/creators/saber", contact: false }}, payload(@post, User.anonymous)[:oc_owners])
    end

    should "drop the mark once the claim is released" do
      CharacterClaim.sole.release!(by: @saber)

      assert_equal({}, payload(@post, @member)[:oc_owners])
    end

    should "ride the JSON next-post payload too" do
      get_auth post_modulation_path(@post), @member

      assert_response :success
      assert_equal({ "name" => "Saber Studio", "href" => "/creators/saber", "contact" => false }, response.parsed_body.dig("oc_owners", "maple_(saber)"))
    end
  end

  context "the creator gallery" do
    should "list its characters, with links for a member" do
      get_auth creator_gallery_path(@gallery), @member

      assert_response :success
      assert_select ".modcreator-characters li", count: 1
      assert_select ".modcreator-characters a[href='/posts?tags=maple_%28saber%29']"
      assert_select ".modcreator-characters a[href='#{wiki_page_path("maple_(saber)")}']"
    end

    should "list plain names to a signed-out visitor" do
      Danbooru.config.stubs(:anonymous_default_deny?).returns(true)
      get creator_gallery_path(@gallery)

      assert_response :success
      assert_select ".modcreator-characters li", text: /maple \(saber\)/
      assert_select ".modcreator-characters a", count: 0
    end
  end

  context "the search excerpt" do
    should "carry the 'Original character of' line on a claimed tag's wiki" do
      as(@saber) { create(:wiki_page, title: "maple_(saber)", body: "mine") }
      as(@member) { create(:wiki_page, title: "hilda_(pokemon)", body: "theirs") }

      get_auth posts_path(tags: "maple_(saber)"), @member
      assert_select "#excerpt #wiki-page-original-character", text: /Original character of Saber Studio/

      get_auth posts_path(tags: "hilda_(pokemon)"), @member
      assert_select "#excerpt #wiki-page-original-character", count: 0
    end

    should "carry it on the Modulation index, the one every viewer gets" do
      as(@saber) { create(:wiki_page, title: "maple_(saber)", body: "mine") }
      as(@member) { create(:wiki_page, title: "hilda_(pokemon)", body: "theirs") }

      get_auth posts_path(tags: "maple_(saber)", preset: "modulation"), @member
      assert_select ".modgal-excerpt--wiki #wiki-page-original-character", text: /Original character of Saber Studio/
      assert_select ".modgal-excerpt--wiki #wiki-page-original-character a[href='/creators/saber']"

      get_auth posts_path(tags: "hilda_(pokemon)", preset: "modulation"), @member
      assert_select ".modgal-excerpt--wiki"
      assert_select "#wiki-page-original-character", count: 0
    end
  end
end
