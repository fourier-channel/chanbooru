# frozen_string_literal: true

require "test_helper"

# THE FLANK CANDIDATES. The post view's previous/next thumbnails were one post
# a side with no tags, so the client-side blocklist never saw them and a
# blocked post sat beside the centre in plain view (users, 2026-10-17). The
# blocklist stays client-side on purpose -- a block added or lifted re-filters
# the page in place -- so each side now carries up to PostNeighbors::DEPTH
# candidates with the tags the engine matches on, and the page shows the
# first one the blocklist allows (GALLERY_WINDOW.md section 2).
#
# The tags travel, so this is also a disclosure surface: everything a post's
# own page withholds from this viewer is withheld here, and a post that does
# not exist for them is in no list and no map at all.
class ModulationFlankCandidatesTest < ActionDispatch::IntegrationTest
  include TagQuarantineTestHelper

  REF_KEYS = %w[id url].freeze
  PRESET_KEYS = %w[key label search prev_candidates next_candidates prev_more next_more].freeze

  def component(post, viewer, query: "flankq")
    ModulationPostComponent.new(post: post, viewer: viewer, query: query)
  end

  def payload_json(post, user, query: "flankq")
    get_auth post_modulation_path(post, format: :json, q: query), user
    assert_response :success
    response.parsed_body
  end

  def candidate_ids(body)
    body.fetch("presets").flat_map { |p| (p.fetch("prev_candidates") + p.fetch("next_candidates")).pluck("id") }.uniq
  end

  # Every statement Active Record sends while the block runs.
  def statements
    sqls = []
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| sqls << payload[:sql] unless payload[:name] == "SCHEMA" }
    yield
    sqls
  ensure
    ActiveSupport::Notifications.unsubscribe(sub)
  end

  setup do
    @viewer = create(:user)
    @uploader = create(:user)
    # Seven newer than the centre (one past DEPTH, so prev_more), six older
    # (exactly DEPTH, so not next_more).
    @posts = as(@uploader) { (0...14).map { create(:post, uploader: @uploader, tag_string: "flankq") } }
    @centre = @posts[6]
  end

  context "the payload" do
    should "carry DEPTH candidate refs a side, nearest first, and every candidate once in one map" do
      payload = as(@viewer) { component(@centre, @viewer).payload }
      presets = payload[:presets]
      candidates = payload[:candidates]

      assert_not_empty presets
      presets.each do |p|
        assert_not p.key?(:prev), "the old single-neighbour key is gone"
        assert_not p.key?(:next), "the old single-neighbour key is gone"
        %i[prev_candidates next_candidates].each do |side|
          assert_kind_of Array, p[side]
          assert_operator p[side].size, :<=, PostNeighbors::DEPTH
          p[side].each do |ref|
            assert_equal REF_KEYS, ref.keys.map(&:to_s).sort
            assert candidates.key?(ref[:id]), "##{ref[:id]} in #{p[:key]} #{side} has no candidates entry"
          end
        end
        assert_includes [true, false], p[:prev_more]
        assert_includes [true, false], p[:next_more]
      end

      search = presets.find { it[:key] == "search" }
      nav = PostNeighbors.new(post: @centre, tags: search[:search], user: @viewer)
      assert_equal nav.run(:next)[:ids], search[:next_candidates].pluck(:id), "nearest first, in display order"
      assert_equal nav.run(:prev)[:ids], search[:prev_candidates].pluck(:id)
      assert_equal PostNeighbors::DEPTH, search[:prev_candidates].size
      assert_equal PostNeighbors::DEPTH, search[:next_candidates].size
      assert_equal true, search[:prev_more]
      assert_equal false, search[:next_more]

      # search and all overlap here, entirely: each post is sent once.
      listed = presets.flat_map { (it[:prev_candidates] + it[:next_candidates]).pluck(:id) }
      assert_operator listed.size, :>, listed.uniq.size, "fixture: the presets share candidates"
      assert_equal listed.uniq.sort, candidates.keys.sort
    end

    # The deploy-skew guard: the next key added to a preset is a reviewed change.
    should "give each preset exactly the documented keys" do
      body = payload_json(@centre, @viewer)

      body.fetch("presets").each do |p|
        expected = (p["key"] == "random") ? PRESET_KEYS + ["history"] : PRESET_KEYS
        assert_equal expected.sort, p.keys.sort, "preset #{p["key"]}"
      end
    end

    # One builder for the engine's contract: a candidate's attributes are
    # byte-identical to the ones that post's own page carries.
    should "build each candidate's blocklist attributes with the centre's own builder" do
      payload = as(@viewer) { component(@centre, @viewer).payload }

      assert_not_empty payload[:candidates]
      payload[:candidates].each do |id, entry|
        own = as(@viewer) { ModulationPostComponent.new(post: Post.find(id), viewer: @viewer).blacklist_data }
        assert_equal own, entry[:blacklist], "candidate ##{id}"
        assert_equal Post.find(id).preview_file_url, entry[:thumb]
        assert_equal false, entry[:deleted]
      end
    end

    # The lookahead warms a neighbour's picture from its candidate entry,
    # before that post's payload exists; the URL warmed has to be the one the
    # centre will ask for at the commit, byte for byte, or the warm-up is a
    # second download (modulation_lookahead.js).
    should "carry each candidate's media as that post's own payload names it" do
      payload = as(@viewer) { component(@centre, @viewer).payload }

      assert_not_empty payload[:candidates]
      payload[:candidates].each do |id, entry|
        own = as(@viewer) { ModulationPostComponent.new(post: Post.find(id), viewer: @viewer).payload[:media] }
        assert_equal own.slice(:kind, :src, :poster, :box), entry[:media], "candidate ##{id}"
        assert_predicate entry.dig(:media, :box), :present?
      end
    end

    should "batch the candidates' tags and posts, and read no tags per candidate: the same queries at depth 1 as at DEPTH" do
      count = lambda do |depth|
        original = PostNeighbors::DEPTH
        silence_warnings { PostNeighbors.const_set(:DEPTH, depth) }
        viewer = create(:user)
        sqls = as(viewer) { statements { component(@centre, viewer).payload } }
        # tags: a candidate's media must not build the centre's tagged
        # file name (seo_tags reads every tag of the post), one query each.
        [sqls.count { it.match?(/FROM "fourier_tag_sources"/) }, sqls.count { it.match?(/\ASELECT "posts"\.\* FROM "posts" WHERE "posts"\."id" IN/) }, sqls.count { it.match?(/FROM "tags"/) }]
      ensure
        silence_warnings { PostNeighbors.const_set(:DEPTH, original) }
      end

      count.call(1) # warm the per-process caches
      assert_equal count.call(1), count.call(PostNeighbors::DEPTH)
    end
  end

  context "privacy" do
    setup do
      Danbooru.config.stubs(:banished_posts_withheld?).returns(true)
      CreatorPrefixes.reset!
      CreatorTagRelease.reset_cache!
    end

    teardown do
      CreatorPrefixes.reset!
    end

    # A blocklist cannot match a tag the viewer may not see -- the same trade
    # the centre makes (FourierTagSource.blacklist_tags_for). A private
    # creator tag is its row alone, outside tag_string, as the tunnel writes
    # it (fourier-tunnel 37270f5). A name the prompt holds that is ALSO on the
    # public list is public to everyone (operator ruling 2026-10-19).
    should "withhold a neighbour's private creator tag from everyone but its creator" do
      neighbour = @posts[4]
      FourierTagSource.create!(post: neighbour, tag: "secret_flank_tag", source: FourierTagSource::CREATOR, status: FourierTagSource::APPROVED, public: false, added_by: @uploader.id)
      FourierTagSource.create!(post: neighbour, tag: "listed_flank_tag", source: FourierTagSource::CREATOR, status: FourierTagSource::APPROVED, public: false, added_by: @uploader.id)
      neighbour.update_columns(tag_string: "flankq listed_flank_tag") # rubocop:disable Rails/SkipsModelValidations -- the public list; secret_flank_tag stays its row alone

      body = payload_json(@centre, @viewer)
      assert_includes candidate_ids(body), neighbour.id, "fixture: it is a candidate"
      assert_not_includes body.dig("candidates", neighbour.id.to_s, "blacklist", "data-tags").split, "secret_flank_tag"
      assert_includes body.dig("candidates", neighbour.id.to_s, "blacklist", "data-tags").split, "listed_flank_tag"
      assert_not_includes response.body, "secret_flank_tag"

      body = payload_json(@centre, @uploader)
      assert_includes body.dig("candidates", neighbour.id.to_s, "blacklist", "data-tags").split, "secret_flank_tag"
    end

    should "list no neighbour that does not exist for the viewer, nor any of its tags" do
      hidden = {}
      as(@uploader) do
        hidden[:jailed] = create(:post, uploader: @uploader, tag_string: "flankq only_on_jailed_nb #{Danbooru.config.troll_jail_tag}")
        hidden[:banished] = create(:post, uploader: @uploader, tag_string: "flankq only_on_banished_nb flank_banished_tag")
        hidden[:gated] = create(:post, uploader: @uploader, tag_string: "flankq only_on_gated_nb child")
        hidden[:flagged] = create(:post, uploader: @uploader, tag_string: "flankq only_on_flagged_nb flank_flagged_tag")
        hidden[:creator] = create(:post, uploader: @uploader, tag_string: "flankq only_on_creator_nb")
      end
      centre = as(@uploader) { create(:post, uploader: @uploader, tag_string: "flankq") }

      hidden[:jailed].delete!("troll jail: shock", user: create(:admin_user))
      banish_tags!("flank_banished_tag")
      flag_tags!("flank_flagged_tag")
      maple = create(:user)
      gallery = CreatorGallery.create!(matrix_id: "@maple:41chan.net", slug: "maple-flank", user: maple)
      FourierPostCreator.create!(post: hidden[:creator], mxid: "@maple:41chan.net", recorded_by: @uploader.id)
      gallery.set_default_audience!("private", by: maple)
      CreatorVisibility.forget!

      hidden.each { |why, post| assert post.reload.hidden_from?(@viewer), "fixture: the #{why} neighbour is hidden from a member" }

      body = payload_json(centre, @viewer)
      ids = candidate_ids(body)
      assert_includes ids, @posts.last.id, "fixture: the flanks were built"
      hidden.each do |why, post|
        assert_not_includes ids, post.id, "the #{why} neighbour is listed"
        assert_not body.fetch("candidates").key?(post.id.to_s), "the #{why} neighbour has a candidates entry"
        assert_not_includes response.body, "only_on_#{why}_nb", "a tag of the #{why} neighbour is in the payload"
      end
      assert_not_includes response.body, "flank_banished_tag"
      assert_not_includes response.body, "flank_flagged_tag"
    end

    # A neighbour the search finds but whose picture this viewer may not see
    # (Post#visible?: an artist-banned post, below Approver) is dropped, not
    # sent with no thumbnail -- a blank tile is no destination, and its id
    # and url are not this viewer's to have. Its place is filled from past
    # the list, so the side still holds DEPTH.
    should "drop a neighbour the viewer may not see, and fill its place from past the list" do
      banned = @posts[8]
      banned.update_columns(is_banned: true) # rubocop:disable Rails/SkipsModelValidations -- an artist ban, as the moderation flag sets it
      nav = PostNeighbors.new(post: @centre, tags: "flankq order:id_desc", user: @viewer)
      assert_includes nav.run(:prev)[:ids], banned.id, "fixture: the search finds it"
      assert_not banned.visible?(@viewer), "fixture: its picture is not this viewer's"

      body = payload_json(@centre, @viewer)
      search = body.fetch("presets").find { it["key"] == "search" }
      assert_not_includes candidate_ids(body), banned.id
      assert_not body.fetch("candidates").key?(banned.id.to_s)
      assert_equal (@posts[7..13] - [banned]).map(&:id), search["prev_candidates"].pluck("id"), "nearest first, the gap filled"
      assert_equal false, search["prev_more"], "the fill reached the last post"
      body.fetch("candidates").each_value { |entry| assert_predicate entry["thumb"], :present? }
    end

    # DEPTH such posts in a row were a side with no candidates and `more`
    # true: the page had nothing to look further FROM (their ids never leave
    # the server), so every post past the run was out of reach in that mode.
    # The server tops the side up from its last row instead.
    should "reach past a run of DEPTH neighbours the viewer may not see" do
      run = @posts[7..12]
      run.each { it.update_columns(is_banned: true) } # rubocop:disable Rails/SkipsModelValidations -- artist bans, as the moderation flag sets them
      assert_equal run.map(&:id), PostNeighbors.new(post: @centre, tags: "flankq order:id_desc", user: @viewer).run(:prev)[:ids], "fixture: the run is the whole first window"

      body = payload_json(@centre, @viewer)
      search = body.fetch("presets").find { it["key"] == "search" }
      assert_equal [@posts[13].id], search["prev_candidates"].pluck("id")
      assert_equal false, search["prev_more"]
      run.each { assert_not body.fetch("candidates").key?(it.id.to_s), "the banned ##{it.id} has a candidates entry" }
    end

    # A top-up reads a whole window, so it can find more shown posts than the
    # side has room for. The ones past DEPTH are not sent, and `more` says so
    # even though the read that found them reached the end.
    should "keep more when a top-up read past DEPTH" do
      newer = as(@uploader) { (0...2).map { create(:post, uploader: @uploader, tag_string: "flankq") } }
      @posts[8].update_columns(is_banned: true) # rubocop:disable Rails/SkipsModelValidations -- an artist ban, as the moderation flag sets it

      body = payload_json(@centre, @viewer)
      search = body.fetch("presets").find { it["key"] == "search" }
      assert_equal (@posts[7..13] - [@posts[8]]).map(&:id), search["prev_candidates"].pluck("id")
      assert_equal true, search["prev_more"], "##{newer.map(&:id).join(", #")} lie past the list"
    end

    # The top-up is bounded: past FLANK_FILL_ROUNDS keyset reads the side is
    # sent as it stands, `more` still true, rather than walking the archive.
    should "stop topping a side up after FLANK_FILL_ROUNDS reads" do
      @posts[7..12].each { it.update_columns(is_banned: true) } # rubocop:disable Rails/SkipsModelValidations -- artist bans, as the moderation flag sets them
      original = ModulationPostComponent::FLANK_FILL_ROUNDS
      silence_warnings { ModulationPostComponent.const_set(:FLANK_FILL_ROUNDS, 0) }

      body = payload_json(@centre, @viewer)
      search = body.fetch("presets").find { it["key"] == "search" }
      assert_equal [], search["prev_candidates"]
      assert_equal true, search["prev_more"]
    ensure
      silence_warnings { ModulationPostComponent.const_set(:FLANK_FILL_ROUNDS, original) }
    end
  end
end
