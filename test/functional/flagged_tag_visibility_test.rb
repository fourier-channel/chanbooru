# frozen_string_literal: true

require "test_helper"

# FLAGGED-TAG QUARANTINE, the doors (operator rulings 2026-10-12; memory
# flagged-tags-are-a-review-quarantine). An admin flags a tag and "the tag's
# entire existence should immediately disappear" for everyone but:
#
#   - Admin level and up (Owner included);
#   - the booru's system user;
#   - a posting bot, on its OWN posts ("they would retain the ability to
#     interact with their own posts while the surface would be shut to every
#     other account").
#
# Every post carrying the tag, at every door, and the tag's NAME. Release
# restores all of it at once. Each door a viewer below admin would try is
# asked here, with the admin, the uploading bot and the OTHER bot beside it.
class FlaggedTagVisibilityTest < ActionDispatch::IntegrationTest
  include TagQuarantineTestHelper

  SECRET = "secret_(thing)"

  def md5 = SecureRandom.hex(16)

  def ids_for(user, **params)
    if user
      get_auth(posts_path(format: :json), user, params: params)
    else
      reset!
      get(posts_path(format: :json), params: params)
    end
    assert_response :success
    response.parsed_body.pluck("id")
  end

  def status_for(path, user, **params)
    if user
      get_auth(path, user, params: params)
    else
      reset!
      get(path, params: params)
    end
    response.status
  end

  def json_for(path, user, **params)
    if user
      get_auth(path, user, params: params)
    else
      reset!
      get(path, params: params)
    end
    assert_response :success, "#{path} #{params.inspect}"
    response.parsed_body
  end

  def autocomplete_values(user, query, type = "tag_query")
    if user
      get_auth(autocomplete_index_path(format: :json), user, params: { search: { query: query, type: type }})
    else
      reset!
      get(autocomplete_index_path(format: :json), params: { search: { query: query, type: type }})
    end
    assert_response :success
    response.parsed_body.pluck("value")
  end

  def below_admin
    { "anonymous" => nil, "member" => @member, "gold" => @gold, "builder" => @builder, "moderator" => @moderator, "approver" => @approver }
  end

  setup do
    @tunnel = create(:contributor_user, name: "tunnel")
    @sample = create(:approver_user, name: "sample")
    @member = create(:user)
    @gold = create(:gold_user)
    @builder = create(:builder_user)
    @moderator = create(:moderator_user)
    @approver = create(:approver_user)
    @admin = create(:admin_user)
    @owner = create(:owner_user)

    as(@tunnel) do
      @flagged = create(:post, uploader: @tunnel, md5: md5, tag_string: "landscape #{SECRET} only_on_flagged", source: "mxc://41chan.net/flagged")
      @plain = create(:post, uploader: @tunnel, md5: md5, tag_string: "landscape")
    end
    as(@sample) { @sample_flagged = create(:post, uploader: @sample, md5: md5, tag_string: "landscape #{SECRET}") }

    as(@admin) do
      @wiki = create(:wiki_page, title: SECRET, body: "a secret thing")
      @alias = create(:tag_alias, antecedent_name: "old_secret", consequent_name: SECRET, status: "active")
      @implication = create(:tag_implication, antecedent_name: SECRET, consequent_name: "landscape", status: "active")
    end
    FourierTagSource.create!(post: @flagged, tag: SECRET, source: FourierTagSource::AUTO, status: FourierTagSource::APPROVED, public: true)
    FourierTagSource.create!(post: @flagged, tag: "landscape", source: FourierTagSource::AUTO, status: FourierTagSource::APPROVED, public: true)

    TagQuarantine.flag!(Tag.find_by_name!(SECRET), by: @admin, note: "review")
  end

  context "a post carrying a flagged tag" do
    should "be not found for everyone below admin, by page, json, modulation.json and md5" do
      below_admin.each do |who, user|
        [@flagged, @sample_flagged].each do |post|
          assert_equal 404, status_for(post_path(post), user), "#{who} page ##{post.id}"
          assert_equal 404, status_for(post_path(post, format: :json), user), "#{who} json"
          assert_equal 404, status_for(post_modulation_path(post, format: :json), user), "#{who} modulation.json"
          assert_empty ids_for(user, tags: "md5:#{post.md5}"), "#{who} md5"
        end
        assert_equal 200, status_for(post_path(@plain, format: :json), user), "#{who} still reaches an ordinary post"
      end
    end

    should "be left out of listings, searches and counts, even searched by the tag" do
      below_admin.each do |who, user|
        ids = ids_for(user, tags: "landscape", limit: 100)
        assert_includes ids, @plain.id, who
        assert_not_includes ids, @flagged.id, who
        assert_empty ids_for(user, tags: SECRET), who
        assert_empty ids_for(user, tags: "id:#{@flagged.id}"), who
      end
      assert_equal 1, PostSets::Post.new("landscape", 1, 20, user: @member).post_count
    end

    should "be seen whole by Admin and Owner level, and the system user" do
      [@admin, @owner].each do |user|
        assert_equal 200, status_for(post_path(@flagged, format: :json), user), user.level_string
        assert_equal [@flagged.id, @sample_flagged.id].sort, ids_for(user, tags: SECRET).sort, user.level_string
      end
      assert_not @flagged.hidden_from?(User.system)
    end

    should "be seen by the bot that uploaded it, and not by the other bot" do
      assert_equal 200, status_for(post_path(@flagged, format: :json), @tunnel)
      assert_equal [@flagged.id], ids_for(@tunnel, tags: "md5:#{@flagged.md5}")
      assert_equal 404, status_for(post_path(@sample_flagged, format: :json), @tunnel)
      assert_equal [@sample_flagged.id], ids_for(@sample, tags: SECRET)
      assert_equal 404, status_for(post_path(@flagged, format: :json), @sample)
    end

    should "let the uploading bot keep tagging its own flagged post, and refuse the other bot" do
      put_auth post_path(@flagged, format: :json), @tunnel, params: { post: { tag_string: "landscape #{SECRET} only_on_flagged sky" }}
      assert_response :success
      assert @flagged.reload.has_tag?("sky")

      put_auth post_path(@flagged, format: :json), @sample, params: { post: { tag_string: "landscape #{SECRET}" }}
      assert_response 404

      get_auth "/posts/#{@flagged.id}/tag_sources.json", @tunnel, params: { scope: "public" }
      assert_response :success
      post_auth "/posts/#{@flagged.id}/tag_sources.json", @tunnel, params: { auto: ["sky"] }, as: :json
      assert_response :success
      post_auth "/posts/#{@flagged.id}/tag_sources.json", @sample, params: { auto: ["sky"] }, as: :json
      assert_response 404
      get_auth "/posts/#{@flagged.id}/tag_sources.json", @sample, params: { scope: "public" }
      assert_response 404
    end

    should "never let a moderator write past it" do
      put_auth post_path(@flagged, format: :json), @moderator, params: { post: { tag_string: "landscape" }}
      assert_response 404
      assert @flagged.reload.has_tag?(SECRET)
    end

    should "agree, relation and predicate, row for row, for every viewer" do
      posts = [@flagged, @sample_flagged, @plain]
      [nil, User.anonymous, @member, @moderator, @approver, @admin, @owner, @tunnel, @sample, User.system].each do |viewer|
        relation = Post.hidden_from(viewer)
        by_relation = relation.nil? ? [] : relation.where(id: posts.map(&:id)).pluck(:id).sort
        by_predicate = posts.select { |post| post.hidden_from?(viewer) }.map(&:id).sort
        assert_equal by_predicate, by_relation, viewer&.name || "nil"
      end
    end

    should "not be drawn on the landing page or the error page" do
      assert_not LandingShowcase.showable?(@flagged, User.anonymous)
      assert_not LandingShowcase.showable?(@flagged, @member)
      assert LandingShowcase.showable?(@plain, @member)
    end
  end

  context "the flagged name" do
    should "be absent from the tag index, its page, and its json for everyone below admin" do
      below_admin.each do |who, user|
        assert_empty json_for(tags_path(format: :json), user, search: { name: SECRET }), who
        assert_equal 404, status_for(tag_path(Tag.find_by_name(SECRET), format: :json), user), who
      end
      assert_equal [SECRET], json_for(tags_path(format: :json), @admin, search: { name: SECRET }).pluck("name")
      assert_equal [SECRET], json_for(tags_path(format: :json), @tunnel, search: { name: SECRET }).pluck("name")
    end

    should "not autocomplete, by itself or through the alias that leads to it" do
      [nil, @member, @moderator].each do |user|
        assert_not_includes autocomplete_values(user, "secret"), SECRET, user&.level_string
        assert_not_includes autocomplete_values(user, "old_sec"), SECRET, user&.level_string
      end
      assert_includes autocomplete_values(@admin, "secret"), SECRET
    end

    # The wiki_page and artist completions read their own tables, not the
    # tag list the withholding chain sees (review pass 2026-10-12).
    should "not autocomplete as a wiki page title or an artist name" do
      as(@admin) { create(:artist, name: SECRET) } if Tag.find_by_name(SECRET).artist?
      [nil, @member, @moderator].each do |user|
        assert_not_includes autocomplete_values(user, "secret", "wiki_page"), SECRET, user&.level_string
      end
      assert_includes autocomplete_values(@admin, "secret", "wiki_page"), SECRET

      as(@tunnel) { create(:post, uploader: @tunnel, md5: md5, tag_string: "artist:hidden_painter landscape") }
      as(@admin) { create(:artist, name: "hidden_painter") }
      TagQuarantine.flag!(Tag.find_by_name!("hidden_painter"), by: @admin)
      [nil, @member, @moderator].each do |user|
        assert_not_includes autocomplete_values(user, "hidden", "artist"), "hidden_painter", user&.level_string
      end
      assert_includes autocomplete_values(@admin, "hidden", "artist"), "hidden_painter"
    end

    should "not be listed among the wiki's recent changes" do
      as(@admin) { create(:wiki_page, title: "landscape", body: "fields") }
      get_auth wiki_page_path("landscape"), @member
      assert_response :success
      assert_select "a[href=?]", wiki_page_path(SECRET), 0
      assert_select "a[href=?]", wiki_page_path("landscape")

      get_auth wiki_page_path("landscape"), @admin
      assert_select "a[href=?]", wiki_page_path(SECRET)
    end

    # An alias or abbreviation typed by a viewer the name is hidden from does
    # not resolve to it: the resolved search is echoed back in the canonical
    # link and the random redirect, which would name the hidden tag.
    should "not be reached through an alias or an abbreviation" do
      [nil, @member].each do |user|
        if user
          get_auth posts_path, user, params: { tags: "old_secret" }
        else
          reset!
          get posts_path, params: { tags: "old_secret" }
        end
        assert_response :success
        assert_no_match(/secret_%28thing%29|secret_\(thing\)/, response.body, user&.level_string || "anonymous")

        get_auth(posts_path, user || @member, params: { tags: "/st", random: "1" })
        assert_no_match(/secret_%28thing%29/, response.headers["Location"].to_s)
      end
      assert_empty ids_for(@member, tags: "old_secret")

      get_auth posts_path, @admin, params: { tags: "old_secret", random: "1" }
      assert_match(/secret_%28thing%29/, response.headers["Location"].to_s, "an admin's alias still resolves")
    end

    should "hide a name that exists only on flagged posts" do
      [nil, @member].each do |user|
        assert_empty json_for(tags_path(format: :json), user, search: { name: "only_on_flagged" }), user&.name || "anonymous"
      end
      assert_equal ["only_on_flagged"], json_for(tags_path(format: :json), @admin, search: { name: "only_on_flagged" }).pluck("name")
    end

    should "make its wiki page, artist-style records, aliases, implications and BURs answer nothing" do
      bur = as(@admin) { create(:bulk_update_request, script: "imply #{SECRET} -> sky", user: @admin) }

      below_admin.except("anonymous").each do |who, user|
        assert_equal 404, status_for(wiki_page_path(@wiki, format: :json), user), "#{who} wiki"
        assert_not_includes json_for(wiki_pages_path(format: :json), user, limit: 100).pluck("title"), SECRET, who
        assert_not_includes json_for(tag_aliases_path(format: :json), user, limit: 100).pluck("id"), @alias.id, who
        assert_equal 404, status_for(tag_alias_path(@alias, format: :json), user), "#{who} alias"
        assert_not_includes json_for(tag_implications_path(format: :json), user, limit: 100).pluck("id"), @implication.id, who
        assert_not_includes json_for(bulk_update_requests_path(format: :json), user, limit: 100).pluck("id"), bur.id, who
      end
      assert_equal 200, status_for(wiki_page_path(@wiki, format: :json), @admin)
      assert_includes json_for(tag_aliases_path(format: :json), @admin, limit: 100).pluck("id"), @alias.id
    end

    should "answer a nested association search as if the name did not exist" do
      rows = json_for(tags_path(format: :json), @member, search: { name: "landscape", consequent_implications: { antecedent_name: SECRET }})
      assert_empty rows
      rows = json_for(tags_path(format: :json), @admin, search: { name: "landscape", consequent_implications: { antecedent_name: SECRET }})
      assert_equal ["landscape"], rows.pluck("name")
    end

    should "be dropped from nested includes" do
      landscape = Tag.find_by_name("landscape")
      rows = json_for(tags_path(format: :json), @member, search: { name: "landscape" }, only: "name,consequent_implications")
      assert_equal [], rows.first["consequent_implications"].to_a
      rows = json_for(tags_path(format: :json), @admin, search: { id: landscape.id }, only: "name,consequent_implications")
      assert_equal [SECRET], rows.first["consequent_implications"].pluck("antecedent_name")
    end

    should "render DText tag-request embeds and links naming it as missing" do
      login_as(@member)
      bur = as(@admin) { create(:bulk_update_request, script: "imply #{SECRET} -> sky", user: @admin) }
      post dtext_preview_path, params: { body: "[ta:#{@alias.id}]\n\n[ti:#{@implication.id}]\n\n[bur:#{bur.id}]\n\n[[#{SECRET}]]" }
      assert_response :success
      assert_no_match(/old_secret/, response.body, "the alias's antecedent")
      assert_match(%r{alias ##{@alias.id}</a> does not exist}, response.body)
      assert_match(%r{implication ##{@implication.id}</a> does not exist}, response.body)
      assert_match(/bulk update request ##{bur.id} does not exist/, response.body)
      assert_no_match(/tag-type-/, response.body, "the typed link is looked up as no tag")

      login_as(@admin)
      post dtext_preview_path, params: { body: "[ta:#{@alias.id}]" }
      assert_match(/old_secret/, response.body)
    end

    should "suppress the tag on the posts index when the name is typed" do
      get_auth posts_path, @member, params: { tags: SECRET }
      assert_response :success
      assert_no_match(/a secret thing/, response.body, "the wiki excerpt")
      assert_no_match(/old_secret/, response.body, "the alias list")
    end

    should "show the never-used page for a flagged name with no wiki" do
      TagQuarantine.flag!(Tag.find_or_create_by_name("loose_secret"), by: @admin)
      get_auth wiki_page_path("loose_secret"), @member
      assert_response 404
      assert_nil css_select("#wiki-page-title a").first&.attribute("class"), "no tag colour"
      assert_select "a[href*='tag_versions']", 0
      get_auth wiki_page_path("never_used_name_xyz"), @member
      assert_nil css_select("#wiki-page-title a").first&.attribute("class"), "a name never used has none either"

      get_auth wiki_page_path("loose_secret"), @admin
      assert_equal "tag-type-0", css_select("#wiki-page-title a").first&.attribute("class")&.value, "an admin sees the tag"
    end

    should "not count or draw a flagged post among an upload's related posts" do
      url = "https://example.com/flagged_source.jpg"
      as(@tunnel) do
        @flagged.update!(source: url)
        @plain.update!(source: url)
      end
      related = ->(user) { CurrentUser.scoped(user) { Source::Extractor.find(url).related_posts.map(&:id) } }
      assert_equal [@plain.id], related.call(@member)
      assert_equal [@flagged.id, @plain.id].sort, related.call(@admin).sort
    end

    should "match nothing in an ai: search" do
      tag = Tag.find_by_name(SECRET)
      AITag.create!(media_asset: @plain.media_asset, tag: tag, score: 90)
      assert_empty ids_for(@member, tags: "ai:#{SECRET}")
      assert_includes ids_for(@admin, tags: "ai:#{SECRET}"), @plain.id
    end

    should "be stripped from the Matrix projection for every caller" do
      projection = FourierTagSource.matrix_projection(@flagged)
      assert_not_includes projection[:tags], SECRET
      assert_includes projection[:tags], "landscape"
      assert_not_includes projection[:sources].values.flatten, SECRET
      assert_not_includes projection[:lamp].values.flatten, SECRET
    end

    should "keep its mod log rows from everyone below admin" do
      flag_row = ModAction.where(category: "tag_flag").last
      [@member, @moderator].each do |user|
        assert_not_includes json_for(mod_actions_path(format: :json), user, limit: 100).pluck("id"), flag_row.id
      end
      assert_includes json_for(mod_actions_path(format: :json), @admin, limit: 100).pluck("id"), flag_row.id
    end

    should "strip it from a visible post's history" do
      @plain.versions.each(&:destroy) if @plain.respond_to?(:versions)
      as(@admin) { @plain.update!(tag_string: "landscape #{SECRET}") }
      as(@admin) { @plain.update!(tag_string: "landscape") }
      rows = json_for(post_versions_path(format: :json), @member, search: { post_id: @plain.id })
      assert rows.none? { |row| row["tags"].to_s.include?(SECRET) || Array(row["added_tags"]).include?(SECRET) || Array(row["removed_tags"]).include?(SECRET) }
      assert_empty json_for(post_versions_path(format: :json), @member, search: { changed_tags: SECRET })
    end
  end

  context "the lock" do
    should "refuse a member adding a flagged name, without naming it" do
      member_post = as(@tunnel) { create(:post, uploader: @tunnel, md5: md5, tag_string: "landscape") }
      put_auth post_path(member_post, format: :json), @builder, params: { post: { tag_string: "landscape #{SECRET}" }}
      assert_not member_post.reload.has_tag?(SECRET)

      as(@builder) { member_post.update(tag_string: "landscape #{SECRET}") }
      message = member_post.errors.full_messages.join
      assert_match(/only an admin may change/, message)
      assert_no_match(/secret/, message)
    end

    should "refuse a public tag that implies a flagged one" do
      as(@admin) { create(:tag_implication, antecedent_name: "leads_to_secret", consequent_name: SECRET, status: "active") }
      member_post = as(@tunnel) { create(:post, uploader: @tunnel, md5: md5, tag_string: "landscape") }
      put_auth post_path(member_post, format: :json), @builder, params: { post: { tag_string: "landscape leads_to_secret" }}
      assert_not member_post.reload.has_tag?("leads_to_secret")
      assert_not member_post.has_tag?(SECRET)
    end

    should "let a bot and an admin add it" do
      post_a = as(@tunnel) { create(:post, uploader: @tunnel, md5: md5, tag_string: "landscape") }
      put_auth post_path(post_a, format: :json), @tunnel, params: { post: { tag_string: "landscape #{SECRET}" }}
      assert_response :success
      post_b = as(@tunnel) { create(:post, uploader: @tunnel, md5: md5, tag_string: "landscape") }
      put_auth post_path(post_b, format: :json), @admin, params: { post: { tag_string: "landscape #{SECRET}" }}
      assert_response :success
      assert_empty ids_for(@member, tags: "id:#{post_a.id},#{post_b.id}")
    end

    # The requester is refused before the script's own checks run, so no
    # refusal tells them more than the generic words -- not that the name is
    # flagged, nor what a move would do (review pass 2026-10-12).
    should "refuse a member's request naming a flagged tag without saying it is flagged" do
      bur = as(@builder) { BulkUpdateRequest.new(user: @builder, script: "rename #{SECRET} -> public_thing", title: "t", reason: "r" * 10) }
      CurrentUser.scoped(@builder) { bur.valid? }
      message = bur.errors.full_messages.join(" ")
      assert_match(/names a tag only an admin may change/, message)
      assert_no_match(/flagged|review|secret/, message)
    end

    should "refuse moving a flagged tag onto a public one, naming the way forward" do
      tag_alias = TagAlias.new(creator: @admin, antecedent_name: SECRET, consequent_name: "public_thing")
      assert_not tag_alias.valid?
      assert_match(/Flag public_thing first, or release/, tag_alias.errors.full_messages.join)
    end
  end

  context "a post that gains the tag later" do
    should "disappear at once" do
      as(@admin) { @plain.update!(tag_string: "landscape #{SECRET}") }
      assert_equal 404, status_for(post_path(@plain, format: :json), @member)
      assert_not_includes ids_for(@member, tags: "landscape"), @plain.id
    end
  end

  context "releasing the flag" do
    should "restore every post and the name at once" do
      TagQuarantine.find_by!(tag: Tag.find_by_name(SECRET)).release!(by: @admin, note: "fine")

      assert_equal 200, status_for(post_path(@flagged, format: :json), @member)
      assert_includes ids_for(@member, tags: SECRET), @flagged.id
      assert_equal [SECRET], json_for(tags_path(format: :json), @member, search: { name: SECRET }).pluck("name")
      assert_equal 200, status_for(wiki_page_path(@wiki, format: :json), @member)
      assert_equal 200, status_for(post_path(@sample_flagged, format: :json), @tunnel)
    end
  end

  context "the Modulation quick switch" do
    should "hand the tag ids and the flagged names to an admin alone" do
      json = json_for(post_modulation_path(@flagged, format: :json), @admin)
      assert_equal [SECRET], json.dig("quarantine", "flagged")
      assert_equal Tag.find_by_name(SECRET).id, json.dig("quarantine", "tag_ids", SECRET)

      assert_nil json_for(post_modulation_path(@plain, format: :json), @member)["quarantine"]
      assert_nil json_for(post_modulation_path(@flagged, format: :json), @tunnel)["quarantine"]
    end

    should "flag and release through the tag's own route as JSON" do
      tag = Tag.find_by_name("landscape")
      login_as(@admin)
      patch tag_path(tag, format: :json), params: { tag: { quarantine: "flag" }}
      assert_response 204
      CreatorVisibility.forget!
      assert_includes TagQuarantine.flagged_names, "landscape"
      patch tag_path(tag, format: :json), params: { tag: { quarantine: "release" }}
      assert_response 204
      CreatorVisibility.forget! # the request had its own per-request memo; this test's is older
      assert_not_includes TagQuarantine.flagged_names, "landscape"
    end
  end

  context "the HTTP caches" do
    should "cache autocomplete publicly only with the current generation, and a minute privately otherwise" do
      reset!
      get autocomplete_index_path(format: :json), params: { search: { query: "lands", type: "tag" }}
      assert_match(/private/, response.headers["Cache-Control"])
      assert_match(/max-age=60/, response.headers["Cache-Control"])
      assert_no_match(/stale-while-revalidate/, response.headers["Cache-Control"])

      get autocomplete_index_path(format: :json), params: { search: { query: "lands", type: "tag" }, tv: TagQuarantine.names_generation }
      assert_match(/public/, response.headers["Cache-Control"])
    end

    should "render the generation in the page for the scripts to send" do
      get_auth posts_path, @member
      assert_select "meta[name=tag-visibility][content=?]", TagQuarantine.names_generation
    end
  end

  # FAIL CLOSED: an unreadable quarantine set shows nothing.
  context "an unreadable quarantine" do
    should "answer no post at all rather than the unfiltered one" do
      TagQuarantine.stubs(:sets).raises(ActiveRecord::StatementInvalid, "quarantine unreadable")
      get_auth post_path(@plain, format: :json), @member
      assert_not_equal 200, response.status
      assert_not_includes response.body, @plain.md5
    end
  end
end
