# frozen_string_literal: true

require "test_helper"

# A hidden post answers nothing, by ANY door (Post#hidden_from?): not the page,
# not the tags, not the id. /posts/:id, its json, modulation.json and the tag
# sources honoured that; every OTHER record that names a post did not. Measured
# anonymously against production on 2026-10-01, for jailed post 413157 whose
# own page 404s:
#
#   /post_versions.json?search[post_id]=  its whole tag history, source, updater
#   /artist_commentaries.json             "Posted by X in /trash/ thread N"
#   /post_flags.json, /mod_actions.json   "troll jail: shock" with the post id
#   /post_events.json, /favorites.json    the id, who faved it
#   /counts/posts.json?tags=id:N          1 -- an existence oracle
#   /related_tag.json?query=troll_jail    the tags jailed posts carry
#   /iqdb_queries.json?post_id=N          the post, its tags, source, uploader
#
# One rule closes all of them (Post.hidden_from, applied by
# ApplicationRecord.paginated_search and ApplicationController#authorize), so
# this file asks each door the same three questions: a signed-out visitor and
# a member see nothing of a jailed or deleted post, and an admin with
# reveal_banished on sees what they saw before.
#
# Deleted-post visibility and the banished-post rule are both relaxed under
# test (the fork restriction pattern), so they are stubbed to the production
# shape here.
class HiddenPostDoorsTest < ActionDispatch::IntegrationTest
  JAIL = "troll_jail"
  BOARD = "https://boards.4chan.org/trash/thread/12345#p12346"
  ATTRIBUTION = "Posted by Anonymous in /trash/ thread 12345, post 12346"
  SECRET = "secret_prompt_tag"
  CREATOR = "@alice:41chan.net"

  def json_ids(path, user = nil, **params)
    user ? get_auth(path, user, params: params, as: :json) : get(path, params: params, as: :json)
    assert_response :success, "#{path} #{params.inspect} as #{user&.name || "anonymous"}"
    response.parsed_body.pluck("id")
  end

  def json_rows(path, user = nil, **params)
    user ? get_auth(path, user, params: params, as: :json) : get(path, params: params, as: :json)
    assert_response :success, "#{path} #{params.inspect} as #{user&.name || "anonymous"}"
    response.parsed_body
  end

  def status_of(path, user = nil, **params)
    user ? get_auth(path, user, params: params, as: :json) : get(path, params: params, as: :json)
    response.status
  end

  def count_for(tags, user = nil)
    user ? get_auth(posts_counts_path(format: :json), user, params: { tags: tags }) : get(posts_counts_path(format: :json), params: { tags: tags })
    assert_response :success
    response.parsed_body.dig("counts", "posts")
  end

  def viewers
    { "anonymous" => nil, "member" => @member }
  end

  # The F-B10 post's own version rows: post versions live behind their own
  # connection, so the test database can hold other runs' rows for the same
  # post id.
  def own(rows)
    rows.select { |row| row["post_id"] == @post.id && row["id"] > @first_version }
  end

  context "With deleted and jailed posts hidden as in production" do
    setup do
      Danbooru.config.stubs(:deleted_post_visibility_level).returns(User::Levels::ADMIN)
      Danbooru.config.stubs(:banished_posts_need_reveal?).returns(true)

      @bot = create(:builder_user)
      @member = create(:user)
      @fan = create(:gold_user)
      @admin = create(:admin_user)
      @admin_off = create(:admin_user)
      ModulationSetting.record!(@admin, nil, { "reveal_banished" => "true" })

      as(@bot) do
        @jailed = create(:post, tag_string: "landscape hidden_marker #{JAIL}", source: BOARD, uploader: @bot)
        @deleted = create(:post, tag_string: "landscape deleted_marker", source: BOARD, uploader: @bot)
        @visible = create(:post, tag_string: "landscape", source: BOARD, uploader: @bot)
      end

      [@jailed, @deleted, @visible].each do |post|
        as(@bot) { create(:artist_commentary, post: post, original_title: "", original_description: ATTRIBUTION, translated_title: "", translated_description: "") }
        # A favorite casts an upvote too (Favorite#upvote_post_on_create).
        create(:favorite, post: post, user: @fan)
      end

      @jailed.delete!("troll jail: shock", user: @admin)
      @deleted.delete!("ordinary deletion", user: @admin)
      @jailed.reload
      @deleted.reload

      assert @jailed.is_deleted? && @jailed.has_tag?(JAIL)
      assert @jailed.versions.any?, "fixture: the jailed post has versions"
    end

    context "post versions" do
      should "show a signed-out visitor and a member nothing of a hidden post" do
        viewers.each do |who, user|
          [@jailed, @deleted].each do |post|
            assert_empty json_ids(post_versions_path, user, search: { post_id: post.id }), "#{who}, post ##{post.id}"
          end
          rows = json_rows(post_versions_path, user, limit: 1000)
          assert_not_includes rows.pluck("post_id"), @jailed.id, who
          assert_includes rows.pluck("post_id"), @visible.id, who
        end
      end

      # Matched by post id, not by emptiness: post versions live behind their
      # own connection, so the test database can hold other runs' rows.
      should "not match a hidden post's tags in a tag search" do
        viewers.each do |who, user|
          assert_not_includes json_rows(post_versions_path, user, search: { changed_tags: JAIL }).pluck("post_id"), @jailed.id, who
          assert_not_includes json_rows(post_versions_path, user, search: { tag_matches: "hidden_marker" }).pluck("post_id"), @jailed.id, who
        end
        assert_includes json_rows(post_versions_path, @admin, search: { changed_tags: JAIL }).pluck("post_id"), @jailed.id
      end

      should "still show them to an admin with reveal on, and to the uploader" do
        assert_not_empty json_ids(post_versions_path, @admin, search: { post_id: @jailed.id })
        assert_not_empty json_ids(post_versions_path, @bot, search: { post_id: @jailed.id })
      end

      should "hide a jailed post's versions from an admin with reveal off, as its page is" do
        assert_empty json_ids(post_versions_path, @admin_off, search: { post_id: @jailed.id })
        assert_not_empty json_ids(post_versions_path, @admin_off, search: { post_id: @deleted.id })
      end
    end

    context "artist commentary" do
      should "show a signed-out visitor and a member nothing of a hidden post" do
        viewers.each do |who, user|
          [@jailed, @deleted].each do |post|
            assert_empty json_ids(artist_commentaries_path, user, search: { post_id: post.id }), "#{who}, post ##{post.id}"
            assert_empty json_ids(artist_commentary_versions_path, user, search: { post_id: post.id }), "#{who}, post ##{post.id}"
            assert_equal 404, status_of(post_artist_commentary_path(post), user), "#{who}, post ##{post.id}"
            assert_equal 404, status_of(artist_commentary_path(post.artist_commentary), user), "#{who}, post ##{post.id}"
            assert_equal 404, status_of(artist_commentary_version_path(ArtistCommentaryVersion.where(post_id: post.id).first), user), "#{who}, post ##{post.id}"
          end
          rows = json_rows(artist_commentaries_path, user, search: { original_description_ilike: "*thread 12345*" })
          assert_equal [@visible.id], rows.pluck("post_id"), who
        end
      end

      should "still answer for a visible post, and for an admin with reveal on" do
        assert_equal 200, status_of(post_artist_commentary_path(@visible), @member)
        assert_equal 200, status_of(post_artist_commentary_path(@jailed), @admin)
        assert_not_empty json_ids(artist_commentaries_path, @admin, search: { post_id: @jailed.id })
      end
    end

    context "flags, mod actions, events, favorites and votes" do
      should "show a signed-out visitor and a member nothing of a hidden post" do
        viewers.each do |who, user|
          flags = json_rows(post_flags_path, user, limit: 100)
          assert_not_includes flags.pluck("post_id"), @jailed.id, who
          assert_not_includes flags.pluck("post_id"), @deleted.id, who
          assert flags.none? { |f| f["reason"].to_s.include?("troll jail") }, who
          assert_equal 404, status_of(post_flag_path(@jailed.flags.first), user), who

          actions = json_rows(mod_actions_path, user, limit: 100)
          assert actions.none? { |a| a["description"].to_s.include?("##{@jailed.id}") }, who
          assert actions.none? { |a| a["description"].to_s.include?("##{@deleted.id}") }, who

          events = json_rows(post_events_path, user, limit: 100)
          assert_not_includes events.pluck("post_id"), @jailed.id, who
          assert_equal 404, status_of(post_events_path, user, search: { post_id: @jailed.id }), who
          assert_equal 404, status_of(post_post_events_path(@jailed), user), who

          favs = json_rows(favorites_path, user, search: { user_id: @fan.id })
          assert_equal [@visible.id], favs.pluck("post_id"), who
          assert_equal 404, status_of(favorites_path, user, search: { post_id: @jailed.id }), who

          votes = json_rows(post_votes_path, user, limit: 100)
          assert_not_includes votes.pluck("post_id"), @jailed.id, who
        end
      end

      should "still show them to an admin with reveal on" do
        assert_includes json_rows(post_flags_path, @admin, limit: 100).pluck("post_id"), @jailed.id
        assert json_rows(mod_actions_path, @admin, limit: 100).any? { |a| a["description"].to_s.include?("##{@jailed.id}") }
        assert_includes json_rows(post_events_path, @admin, limit: 100).pluck("post_id"), @jailed.id
        assert_includes json_rows(favorites_path, @admin, search: { user_id: @fan.id }).pluck("post_id"), @jailed.id
      end
    end

    context "post counts" do
      should "not confirm a hidden post exists, or count jailed, deleted or rated posts it holds" do
        viewers.each do |who, user|
          assert_equal 0, count_for("id:#{@jailed.id}", user), who
          assert_equal 0, count_for("id:#{@deleted.id}", user), who
          assert_equal 0, count_for(JAIL, user), who
          assert_equal 0, count_for("status:deleted", user), who
          assert_equal 0, count_for("hidden_marker", user), who
          assert_equal 1, count_for("id:#{@visible.id}", user), who
        end
      end

      should "still count them for an admin with reveal on" do
        assert_equal 1, count_for("id:#{@jailed.id}", @admin)
        assert_operator count_for("status:deleted", @admin), :>=, 2
      end
    end

    context "related tags" do
      should "not tell a signed-out visitor or a member what jailed posts carry" do
        viewers.each do |who, user|
          user ? get_auth(related_tag_path(format: :json), user, params: { query: JAIL }) : get(related_tag_path(format: :json), params: { query: JAIL })
          assert_response :success
          names = response.parsed_body["related_tags"].map { |t| t.dig("tag", "name") }
          assert_not_includes names, "hidden_marker", who
          assert_equal 0, response.parsed_body["post_count"].to_i, who

          user ? get_auth(related_tag_path(format: :json), user, params: { query: "landscape" }) : get(related_tag_path(format: :json), params: { query: "landscape" })
          assert_response :success
          names = response.parsed_body["related_tags"].map { |t| t.dig("tag", "name") }
          assert_not_includes names, JAIL, who
          assert_not_includes names, "hidden_marker", who
        end
      end

      should "still answer an admin with reveal on" do
        get_auth related_tag_path(format: :json), @admin, params: { query: JAIL }
        assert_response :success
        assert_includes response.parsed_body["related_tags"].map { |t| t.dig("tag", "name") }, "hidden_marker"
      end
    end

    context "iqdb" do
      should "not look up a hidden post or its media asset, and not return it as a match" do
        viewers.each do |who, user|
          mock_iqdb_matches([{ post_id: @jailed.id, score: 99.0 }, { post_id: @visible.id, score: 95.0 }])
          assert_equal 404, status_of(iqdb_queries_path, user, post_id: @jailed.id), who
          assert_equal 404, status_of(iqdb_queries_path, user, media_asset_id: @jailed.media_asset.id), who

          rows = json_rows(iqdb_queries_path, user, hash: "0" * 32)
          assert_equal [@visible.id], rows.pluck("post_id"), who
        end
      end

      should "still match a hidden post for an admin with reveal on" do
        mock_iqdb_matches([{ post_id: @jailed.id, score: 99.0 }])
        rows = json_rows(iqdb_queries_path, @admin, hash: "0" * 32)
        assert_equal [@jailed.id], rows.pluck("post_id")
        assert_equal 404, status_of(iqdb_queries_path, @admin_off, media_asset_id: @jailed.media_asset.id)
      end
    end
  end

  # Under test both visibility switches are relaxed, so the rule has to be
  # inert for the inherited suite -- except for gated tags, which a signed-out
  # visitor is never shown in any environment (Post#hidden_from_anonymous?).
  context "Post.hidden_from under the test defaults" do
    should "hide nothing from a member, and only gated posts from a signed-out visitor" do
      assert_nil Post.hidden_from(create(:user))
      gated = as(create(:user)) { create(:post, tag_string: "landscape #{JAIL}") }
      plain = as(create(:user)) { create(:post, tag_string: "landscape") }
      ids = Post.hidden_from(User.anonymous).pluck(:id)

      assert_includes ids, gated.id
      assert_not_includes ids, plain.id
    end
  end

  # F-B10. An earlier version of a VISIBLE post can still carry a private
  # creator tag (FourierPrivateTagCleanup removed it from tag_string through an
  # ordinary, versioned edit, so the version before that edit holds it). The
  # creator decides who sees private data (operator ruling 2026-09-29); there
  # is no admin bypass.
  context "A visible post whose history holds a private creator tag" do
    setup do
      @first_version = PostVersion.maximum(:id).to_i
      @bot = create(:builder_user)
      @admin = create(:admin_user)
      @member = create(:user)
      as(@bot) { @post = create(:post, uploader: @bot, tag_string: "41chan_alice landscape #{SECRET}") }
      FourierTagSource.record_partition!(@post, { creator: [SECRET], auto: %w[landscape] }, @bot)
      FourierPostCreator.create!(post: @post, mxid: CREATOR, recorded_by: @bot.id)
      FourierPrivateTagCleanup.apply!(FourierPrivateTagCleanup.plan, user: @admin)
      assert_not_includes @post.reload.tag_array, SECRET, "fixture: the tag left tag_string"
    end

    should "be withheld from the version history for anyone but the creator" do
      [nil, @member, @admin].each do |user|
        rows = own(json_rows(post_versions_path, user, search: { post_id: @post.id }))
        assert_equal 2, rows.size, user&.name || "anonymous"
        assert_not_includes rows.to_json, SECRET, user&.name || "anonymous"
      end
    end

    should "not be findable by searching the history for it" do
      [nil, @member, @admin].each do |user|
        assert_empty own(json_rows(post_versions_path, user, search: { changed_tags: SECRET })), user&.name || "anonymous"
        assert_empty own(json_rows(post_versions_path, user, search: { tag_matches: SECRET })), user&.name || "anonymous"
      end
    end

    should "still be shown to the creator" do
      get post_versions_path, params: { search: { post_id: @post.id }}, as: :json, headers: { "X-Fourier-Identity" => CREATOR }
      assert_response :success
      assert_includes own(response.parsed_body).to_json, SECRET

      get post_versions_path, params: { search: { changed_tags: SECRET }}, as: :json, headers: { "X-Fourier-Identity" => CREATOR }
      assert_response :success
      assert_equal 2, own(response.parsed_body).size
    end
  end

  # F-B9. An error page's backtrace names the line that raised, so two raise
  # sites -- "hidden" and "no such post" -- answered differently to anyone who
  # read it. Measured on production 2026-10-01: /posts/413157.json carried
  # posts_controller.rb:50.
  context "An error response" do
    setup { Danbooru.config.stubs(:error_backtraces_public?).returns(false) }

    should "carry no backtrace for a signed-out visitor or a member" do
      [nil, create(:user)].each do |user|
        user ? get_auth(post_path(0, format: :json), user) : get(post_path(0, format: :json))
        assert_response 404
        assert_predicate response.parsed_body["backtrace"], :blank?, response.body

        user ? get_auth(root_path, user, params: { cause_error: 500 }) : get(root_path, params: { cause_error: 500 })
        assert_response 500
        assert_no_match(/\.rb:\d+/, response.body)
      end
    end

    should "still carry it for an admin" do
      get_auth post_path(0, format: :json), create(:admin_user)
      assert_response 404
      assert_not_empty response.parsed_body["backtrace"]
    end

    should "answer a hidden post and a missing one identically" do
      Danbooru.config.stubs(:deleted_post_visibility_level).returns(User::Levels::ADMIN)
      hidden = as(create(:user)) { create(:post, tag_string: "landscape #{JAIL}") }
      get post_path(hidden, format: :json)
      gone = response.body
      get post_path(0, format: :json)
      assert_equal gone, response.body
    end
  end
end
