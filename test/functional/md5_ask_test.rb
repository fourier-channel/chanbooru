# frozen_string_literal: true

require "test_helper"

# FOURIER-AUTH'S MD5 ASK: GET /posts.json?tags=md5:<a>,<b>,...&only=md5,is_deleted,source&limit=N,
# asked for every image the media gate serves -- signed out first, then as
# the reader (fourier-auth booru-visibility.js).
#
# Incident 2026-10-19 04:58-05:01 UTC: 78 asks passed fourier-auth's 4 s
# budget and their images were refused with a 503. For a signed-out viewer
# and every non-admin the ask ran the whole gallery path: the pluck of every
# aichan_ post id (~69,600, 0.4 s), a ~530 KB id literal compiled into the
# statement, and an exact COUNT keyed on the md5 batch, so never cached --
# 0.52-1.08 s an ask around a 15 ms SELECT. The ask now counts nothing, as
# a gallery window chunk does (PostSets::Post#md5_ask?), and carries the
# hidden tags as one row filter, as every search does since 2026-10-24
# (PostQuery#hidden_tags_condition); the id list is gone.
#
# The parity guard below is the half that matters: a mistake there serves
# aichan_ or jailed media to non-admins. Its table was asserted against the
# id-list path at 9695185e4 before the change, and must hold after it.
class Md5AskTest < ActionDispatch::IntegrationTest
  include TagQuarantineTestHelper

  LIST = <<~YAML
    editors: [tunnel, sample]
    prefixes:
      - {prefix: 4chan_, provenance: Imageboard/web surface, target_kind: site, target: www.4chan.org, scope: x}
      - {prefix: 41chan_, provenance: Matrix, target_kind: server, target: matrix.41chan.net, scope: x}
      - {prefix: mdmem_, provenance: Test, target_kind: site, target: example.org, scope: x, visible_to: members}
      - {prefix: aichan_, provenance: Discord, target_kind: server, target: AIChan, scope: x, visible_to: admins}
  YAML

  JAIL = "troll_jail"
  FIELDS = "md5,is_deleted,source"

  # The askers whose ask paid for the id list: signed out, and every level
  # an admins-only prefix hides from (by the instance variable each test's
  # setup makes), with the format asked in. A Member is fourier-auth's
  # ordinary reader; one with a gated allow (their own gated upload) has
  # gate 1 as "these tags, or one of my ids" rather than the tags alone.
  ASKERS = {
    "anonymous" => [nil, :json],
    "member" => [:member, :json],
    "member with a gated allow" => [:allowed, :json],
    "gold" => [:gold, :json],
    "moderator" => [:moderator, :json],
    "gold, xml" => [:gold, :xml],
  }.freeze

  # `anonymous` is signed out under production's switches (default-deny, and
  # an md5 answered only for a post the site showed signed out);
  # `anonymous_unguarded` is signed out under the test defaults, with neither.
  # `plain_member`, `restricted` (the level an invitee starts at) and
  # `banned` stand in no relation to any post: no upload, no group, no claim,
  # so nothing gated is let through to them and gate 1 is the gated tags
  # alone (PostQuery#gated_by_name?). `member` uploaded the own_ posts, is in
  # maple's group and holds the approved claim; `member_in_room` is that
  # member as a verified Matrix reader joined to the room the gate-3 post was
  # placed in.
  VIEWERS = %i[anonymous anonymous_unguarded plain_member restricted banned member member_in_room gold moderator admin].freeze
  SIGNED_IN = %i[plain_member restricted banned member member_in_room gold moderator admin].freeze

  # Who the ask answers each post for: derived from the visibility rules
  # (Post#hidden_from? and PostQuery's own terms), and asserted against the
  # id-list path at 9695185e4 before the row filter replaced it.
  EXPECTED = {
    plain: VIEWERS,
    imageboard: VIEWERS,
    released: VIEWERS, # its creator released from the admins-only prefix
    old: VIEWERS - [:anonymous], # never shown signed out
    members_prefix: SIGNED_IN,
    own_gated: %i[member member_in_room gold moderator admin], # gate 1 holds back no one at Gold and up, nor its uploader
    gated: %i[gold moderator admin],
    claimed: %i[member member_in_room admin], # an approved claimant sees their own
    grouped: %i[member member_in_room admin], # the creator's group
    widened: %i[member member_in_room admin], # gated; the creator lets their group past gate 1
    aichan: %i[admin],
    deleted: %i[admin],
    own_deleted: %i[admin], # a search lists no deleted post to its uploader
    closed: %i[admin], # private by its creator
    flagged: %i[admin],
    room_gated: %i[member_in_room], # gate 3: its room's members; admins are held to it
    jailed: [],
    jailed_live: [],
    banished_live: [],
  }.freeze

  def real_md5 = SecureRandom.hex(16)

  # The ask as fourier-auth sends it: these three parameters and no others.
  def ask(user, posts, format: :json, headers: {})
    params = { tags: "md5:#{posts.map(&:md5).join(",")}", only: FIELDS, limit: posts.size }
    if user
      get_auth posts_path(format: format), user, params: params, headers: headers
    else
      # A signed-out request needs a fresh session: an integration test keeps
      # the last request's login cookie.
      reset!
      get posts_path(format: format), params: params, headers: headers
    end
    response
  end

  # Every statement `block` sends, but the schema reads.
  def statements
    sqls = []
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| sqls << payload[:sql] unless payload[:name] == "SCHEMA" }
    yield
    sqls
  ensure
    ActiveSupport::Notifications.unsubscribe(sub)
  end

  # The post counts among `sqls`: the exact COUNT the old path ran, keyed on
  # the md5 batch and so never cached.
  def post_counts(sqls) = sqls.grep(/SELECT COUNT\(.*\) FROM "posts"/i)

  # The pluck of every post under a hidden creator prefix that a search ran
  # until 2026-10-24, before it carried the row filter: 220 ms warm, 2.6 s
  # cold on the dev DB, a request.
  def prefix_plucks(sqls) = sqls.grep(/\ASELECT "posts"\."id" FROM "posts" WHERE string_to_array\(posts\.tag_string, ' '\) && ARRAY\[/)

  # A failed ask's body names what raised (an unexpected call to a method
  # the test forbade answers 500).
  def assert_answered(who)
    assert_response :success, "#{who}: #{response.body.to_s[0, 300]}"
  end

  # Each asker's statements, the ask's own: a viewer's sign-in is done
  # before the recording starts. The cache is emptied first: two askers of
  # one level share a count's cache key, and production's asks never repeat
  # a batch the way these do.
  def recorded
    ASKERS.to_h do |who, (name, format)|
      user = name && instance_variable_get("@#{name}")
      login_as(user)
      Rails.cache.clear
      sqls = statements { ask(user, [@a, @b], format: format) }
      assert_answered(who)
      [who, sqls]
    end
  end

  # The fourier_session cookie and identity a signed-in Matrix reader
  # carries, and fourier-auth's answer for the rooms they are joined to.
  def in_room
    cookies["fourier_session"] = "session-of-md5-member"
    body = { mxid: "@md5_member:41chan.net", rooms: ["!md5room:41chan.net"], count: 1, digest: "d", as_of: Time.zone.now.iso8601 }.to_json
    Danbooru::Http.any_instance.stubs(:get).returns(HTTP::Response.new(status: 200, body: body, version: "1.1", request: nil, headers: { "Content-Type" => "application/json" }))
    { "X-Fourier-Identity" => "@md5_member:41chan.net" }
  end

  def answer(viewer)
    posts = @posts.values
    case viewer
    when :anonymous
      Danbooru.config.stubs(:anonymous_default_deny?).returns(true)
      Danbooru.config.stubs(:post_listings_members_only?).returns(true)
      ask(nil, posts)
    when :anonymous_unguarded
      Danbooru.config.stubs(:anonymous_default_deny?).returns(false)
      Danbooru.config.stubs(:post_listings_members_only?).returns(false)
      ask(nil, posts)
    when :member_in_room then ask(@member, posts, headers: in_room)
    else ask(instance_variable_get("@#{viewer}"), posts)
    end
    assert_answered(viewer)
    response.parsed_body
  end

  setup do
    @dir = Dir.mktmpdir("md5-ask")
    @path = File.join(@dir, "creator_prefixes.yml")
    File.write(@path, LIST)
    @was = ENV.fetch("FOURIER_CREATOR_PREFIXES", nil)
    ENV["FOURIER_CREATOR_PREFIXES"] = @path
    CreatorPrefixes.reset!
  end

  teardown do
    ENV["FOURIER_CREATOR_PREFIXES"] = @was
    CreatorPrefixes.reset!
    FileUtils.rm_rf(@dir)
  end

  context "The md5 ask's cost" do
    setup do
      @tunnel = create(:builder_user, name: "tunnel")
      @member = create(:user)
      @allowed = create(:user)
      @gold = create(:gold_user)
      @moderator = create(:moderator_user)
      as(@allowed) { create(:post, uploader: @allowed, md5: real_md5, tag_string: "landscape child") }
      as(@tunnel) do
        # The posts the old path plucked and inlined: past LONG_IN_LIST, where
        # the id list goes into the statement as one unnest('{...}') literal,
        # as production's ~69,600 do. Copies of one post, for speed.
        hidden = create(:post, uploader: @tunnel, md5: real_md5, tag_string: "aichan_hidden landscape")
        Post.insert_all(Array.new(Searchable::LONG_IN_LIST) { hidden.attributes.except("id").merge("md5" => real_md5) }) # rubocop:disable Rails/SkipsModelValidations
        @a = create(:post, uploader: @tunnel, md5: real_md5, tag_string: "4chan_bob landscape")
        @b = create(:post, uploader: @tunnel, md5: real_md5, tag_string: "landscape")
      end
      CreatorVisibility.forget!
    end

    context "under the test defaults" do
      ASKERS.each do |who, (name, format)|
        should "not pluck the hidden creator-prefix post ids, asked by #{who}" do
          user = name && instance_variable_get("@#{name}")
          login_as(user)
          sqls = statements { ask(user, [@a, @b], format: format) }
          assert_answered(who)
          assert_empty prefix_plucks(sqls)
        end
      end

      should "count no posts, for any asker" do
        counted = recorded.transform_values { |sqls| post_counts(sqls).map { |sql| sql[0, 160] } }.reject { |_who, sqls| sqls.empty? }
        assert_empty counted, "these asks counted posts"
      end

      should "inline no id list, for any asker" do
        assert_empty recorded.select { |_who, sqls| sqls.any? { |sql| sql.include?("unnest('{") } }.keys, "these asks inlined an id list"
      end

      should "answer the posts each viewer sees, in the fields asked for" do
        assert_equal [@b.md5, @a.md5], ask(@gold, [@a, @b]).parsed_body.pluck("md5")
        assert_equal %w[is_deleted md5 source], response.parsed_body.flat_map(&:keys).uniq.sort
        assert_equal [@b.md5, @a.md5], ask(nil, [@a, @b]).parsed_body.pluck("md5")
      end
    end

    # Signed out, production refuses every door but the listed ones and
    # answers an md5 only for a post the site has shown signed out
    # (MembersOnly.anonymous_md5_rows), which reads the newest page, cached
    # for 30 s. The first ask after a quiet spell builds that page, and on a
    # quiet site that is most bursts' first wave: it is measured here as
    # well as the asks after it.
    context "signed out, under the production switches" do
      setup do
        Danbooru.config.stubs(:anonymous_default_deny?).returns(true)
        Danbooru.config.stubs(:post_listings_members_only?).returns(true)
        Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
      end

      should "not pluck the hidden ids, count, or inline a list, building the newest page" do
        sqls = statements { ask(nil, [@a, @b]) }
        assert_answered("anonymous")
        assert_equal [@b.md5, @a.md5], response.parsed_body.pluck("md5")
        assert_empty prefix_plucks(sqls)
        assert_empty post_counts(sqls)
        assert_empty sqls.select { |sql| sql.include?("unnest('{") }
      end

      # A burst after a quiet spell: the first ask rebuilds the newest page,
      # and an ask arriving while it does is served the ids just expired
      # instead of rebuilding them too. The rebuild in flight is modelled as
      # one that has not finished -- it raises -- with the next ask after it.
      should "serve the ids just expired to an ask arriving while the first rebuilds them" do
        shown = MembersOnly.anonymous_newest_ids(false)
        assert_includes shown, @a.id, "fixture: the newest page"

        travel 4.minutes do
          PostQuery.expects(:normalize).once.raises(ActiveRecord::QueryCanceled, "the rebuild in flight")
          assert_raises(ActiveRecord::QueryCanceled) { MembersOnly.anonymous_newest_ids(false) }
          assert_equal shown, MembersOnly.anonymous_newest_ids(false)
        end
      end

      context "once the newest page is cached" do
        setup do
          assert_equal [@b.md5, @a.md5], ask(nil, [@a, @b]).parsed_body.pluck("md5"), "fixture: the newest page shows both"
        end

        should "not pluck the hidden ids, count, or inline a list" do
          sqls = statements { ask(nil, [@a, @b]) }
          assert_answered("anonymous")
          assert_equal [@b.md5, @a.md5], response.parsed_body.pluck("md5")
          assert_empty prefix_plucks(sqls)
          assert_empty post_counts(sqls)
          assert_empty sqls.select { |sql| sql.include?("unnest('{") }
        end
      end
    end

    # EVERY OTHER IMPLICIT SEARCH paid what the md5 ask paid until 2026-10-24:
    # the pluck, on every request (220 ms warm, 2.6 s cold on the dev DB's
    # 1.21M posts), then the literal in each statement -- production's
    # signed-out /posts.json?limit=1 took 0.70-1.21 s warm, mostly those two.
    # Each now carries the hidden tags as one row filter
    # (PostQuery#hidden_tags_condition). A search that counts is asked one
    # the estimates do not cover, so the exact count runs.
    context "every other implicit search" do
      setup do
        as(@tunnel) { create(:post, uploader: @tunnel, md5: real_md5, tag_string: "artist:md5cost_artist landscape") }
        @artist = as(@tunnel) { create(:artist, name: "md5cost_artist") }
        @wiki = as(@tunnel) { create(:wiki_page, title: "landscape") }
        ModulationSetting.record!(@member, nil, { "gallery_sort" => "score" })
        CreatorVisibility.forget!
      end

      count_tags = "landscape -4chan_bob"
      {
        "the gallery, signed out" => lambda {
          reset!
          get posts_path
        },
        "the API's limit=1, signed out" => lambda {
          reset!
          get posts_path(format: :json), params: { limit: 1 }
        },
        "the gallery, as a member" => -> { get_auth posts_path, @member },
        "the API's limit=1, as a member" => -> { get_auth posts_path(format: :json), @member, params: { limit: 1 } },
        "a member's tag page under a remembered sort" => -> { get_auth posts_path, @member, params: { preset: "modulation", tags: "landscape" } },
        "a window chunk" => -> { get_auth posts_path, @member, params: { preset: "modulation", variant: "window", tags: "landscape order:score" } },
        "the front page's pulse" => -> { [User.anonymous, @member].each { |viewer| ArchivePulse.new(viewer: viewer).then { [it.newest_at, it.cadence] } } },
        "an artist's post strip" => -> { get_auth artist_path(@artist), @member },
        "a wiki page's post strip" => -> { get_auth wiki_page_path(@wiki), @member },
        "/counts/posts" => -> { get_auth posts_counts_path(format: :json), @member, params: { tags: count_tags } },
        "the Discord count" => -> { DiscordSlashCommand::CountCommand.new(data: { data: { options: [{ name: "tags", value: count_tags }] }}).call },
      }.each do |surface, run|
        should "carry no hidden-post pluck or id list, and no statement over 20 KB: #{surface}" do
          sqls = statements { instance_exec(&run) }
          assert_response :success unless surface.in?(["the front page's pulse", "the Discord count"])
          assert_not_empty sqls.grep(/FROM "posts"/), "fixture: #{surface} searched the posts"
          assert_empty prefix_plucks(sqls).map { |sql| sql[0, 160] }, "plucked the hidden posts"
          # A long post-id list: the one-literal form past
          # Searchable::LONG_IN_LIST, or a plain NOT IN of over 1,000 ids. The
          # small per-viewer lists (a creator's panel, the quarantine) stay ids.
          assert_empty sqls.select { |sql| sql.include?("unnest('{") || sql[/"posts"\."id" NOT IN \(([^)]*)\)/, 1].to_s.count(",") >= 1_000 }.map { |sql| sql[0, 160] }, "inlined an id list"
          assert_empty sqls.select { |sql| sql.include?('FROM "posts"') && sql.bytesize >= 20_000 }.map { |sql| "#{sql.bytesize} B: #{sql[0, 120]}" }
        end
      end
    end
  end

  # THE PARITY GUARD. One post per way a post is hidden, plus visible
  # controls; for each viewer, the rows the ask answers. A row here that a
  # viewer should not get is media served to someone it is hidden from.
  context "The md5 ask's answer" do
    setup do
      Danbooru.config.stubs(:deleted_post_visibility_level).returns(User::Levels::ADMIN)
      Danbooru.config.stubs(:banished_posts_withheld?).returns(true)
      Danbooru.config.stubs(:gate3_matrix_posts_enforced?).returns(true)
      # A real cache, so what the site showed signed out is remembered
      # (MembersOnly.remember_shown_to_anonymous); the test default is the
      # null store.
      Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)

      @tunnel = create(:builder_user, name: "tunnel")
      @admin = create(:admin_user)
      @member = create(:user, name: "md5_member")
      @plain_member = create(:user)
      @restricted = create(:restricted_user)
      @banned = create(:banned_user)
      @gold = create(:gold_user)
      @moderator = create(:moderator_user)
      @maple = create(:user)

      gallery = CreatorGallery.create!(matrix_id: "@maple:41chan.net", slug: "maple-md5", user: @maple)
      tier = CreatorGroup.make!(gallery, name: "41chan_maple_tier_1", tier: 1, by: @maple)
      tier.add_member!(@member, by: @maple)
      record = ->(post) { FourierPostCreator.create!(post: post, mxid: gallery.matrix_id, recorded_by: @tunnel.id) && post }
      make = ->(tags, **attrs) { create(:post, uploader: @tunnel, md5: real_md5, tag_string: tags, **attrs) }

      @posts = {}
      as(@tunnel) do
        # Older than the newest page, and never remembered as shown: a
        # signed-out ask leaves it out under production's switches.
        @posts[:old] = make.call("landscape", created_at: 2.days.ago)
        @posts[:plain] = make.call("landscape")
        @posts[:imageboard] = make.call("4chan_bob landscape")
        @posts[:jailed] = make.call("landscape #{JAIL}")
        @posts[:jailed_live] = make.call("landscape #{JAIL}")
        @posts[:banished_live] = make.call("landscape md5_banished")
        @posts[:gated] = make.call("landscape child")
        @posts[:aichan] = make.call("aichan_alice landscape")
        @posts[:members_prefix] = make.call("mdmem_carol landscape")
        @posts[:deleted] = make.call("landscape")
        @posts[:flagged] = make.call("landscape md5_flagged")
        @posts[:room_gated] = make.call("landscape", source: "mxc://41chan.net/md5room")
        @posts[:released] = make.call("aichan_rel landscape")
        @posts[:claimed] = make.call("aichan_dave landscape")
        @posts[:grouped] = record.call(make.call("landscape cv_md5"))
        @posts[:closed] = record.call(make.call("landscape cv_md5"))
        @posts[:widened] = record.call(make.call("landscape child"))
      end
      as(@member) do
        @posts[:own_gated] = create(:post, uploader: @member, md5: real_md5, tag_string: "landscape child")
        @posts[:own_deleted] = create(:post, uploader: @member, md5: real_md5, tag_string: "landscape")
      end
      # The newest page a signed-out viewer is shown, so :old is not on it.
      @fillers = as(@tunnel) { Array.new(2) { create_list(:post, 10, uploader: @tunnel, tag_string: "landscape md5_filler") }.flatten }

      @posts[:jailed].delete!("troll jail: shock", user: @admin)
      @posts[:jailed_live].update!(is_deleted: false) if @posts[:jailed_live].reload.is_deleted?
      @posts[:deleted].delete!("ordinary deletion", user: @admin)
      @posts[:own_deleted].delete!("ordinary deletion", user: @admin)
      banish_tags!("md5_banished")
      flag_tags!("md5_flagged")

      gallery.set_default_audience!("groups", by: @maple, group_ids: [tier.id])
      CreatorPostAudience.set!(@posts[:closed], gallery: gallery, audience: "private", by: @maple)

      CreatorTagRelease.set!("aichan_rel", released: true, by: @admin)
      as(@admin) do
        Tag.find_by_name("aichan_dave").update!(category: Tag.categories.artist, updater: @admin)
        @artist = create(:artist, name: "aichan_dave")
      end
      claim_gallery = CreatorGallery.create!(matrix_id: "@dave:41chan.net", slug: "dave-md5", user: @member)
      ArtistClaim.create!(artist: @artist, creator_gallery: claim_gallery).approve!(by: @admin)

      room = MatrixRoom.intern!(["!md5room:41chan.net"]).fetch("!md5room:41chan.net")
      MatrixMedia.create!(mxc: @posts[:room_gated].source, room_ids: [room], site_asset: false, snapshot_head: 1, snapshot_at: Time.zone.now)
      PostMxc.recompute_room_ids!([@posts[:room_gated].id])

      # Shown signed out, as far as the md5 ask's own filter is concerned:
      # everything but :old, so what keeps a hidden post out of a signed-out
      # answer below is the search, not the shown set.
      MembersOnly.remember_shown_to_anonymous(@posts.except(:old).values.map(&:id), safe_mode: false)
      @posts.each_value(&:reload)
      CreatorVisibility.forget!

      assert @posts[:jailed].is_deleted? && @posts[:jailed].has_tag?(JAIL), "fixture: jailed"
      assert_not @posts[:jailed_live].is_deleted?, "fixture: a live post carrying the jail tag"
      assert_not @posts[:banished_live].is_deleted?, "fixture: a live post carrying a banished tag"
      assert_equal [room], @posts[:room_gated].room_ids, "fixture: placed in its room alone"
      assert_operator @posts.size, :<=, 20, "fixture: one ask carries at most 20 md5s"
    end

    should "hold every class to the table, for every viewer" do
      assert_equal EXPECTED.keys.sort, @posts.keys.sort, "every class has a row in the table"
      name_of = @posts.to_h { |name, post| [post.md5, name] }
      answers = VIEWERS.to_h do |viewer|
        CreatorVisibility.forget!
        [viewer, answer(viewer)]
      end

      # Every viewer's leaks and gaps at once, so a broken rule names
      # everyone it reaches. A row whose md5 the API withheld (a post the
      # viewer may not see the file of) is a leak all the same, named by
      # the row itself.
      wrong = answers.to_h do |viewer, rows|
        got = rows.map { |row| name_of.fetch(row["md5"], row) }
        want = EXPECTED.select { |_name, viewers| viewers.include?(viewer) }.keys
        [viewer, { leaked: got - want, missing: want - got }]
      end
      assert_empty wrong.reject { |_viewer, diff| diff.values.all?(&:empty?) }, "the md5 ask answered these viewers wrongly"

      # And each answer whole: the fields asked for, newest first.
      answers.each do |viewer, rows|
        expected = @posts.values.select { |post| EXPECTED[name_of[post.md5]].include?(viewer) }.sort_by(&:id).reverse
        assert_equal expected.map { |post| { "md5" => post.md5, "is_deleted" => post.is_deleted?, "source" => post.source } }, rows, viewer.to_s
      end
    end

    # Every search carries the hidden tags as the ask's own row filter since
    # 2026-10-24, where it carried the id list: the gallery's searches, held
    # to the same table. Signed out is unguarded here: the guarded door
    # answers a listing nothing (post_listings_members_only?). A random draw
    # is held only to what it may not show. The fillers are deleted: a page
    # below Gold is capped short of 200 rows, and they are the newest.
    should "hold every search to the table, for every viewer" do
      Post.where(id: @fillers.map(&:id)).update_all(is_deleted: true) # rubocop:disable Rails/SkipsModelValidations
      name_of = @posts.to_h { |name, post| [post.id, name] }
      searches = ["landscape", "", "landscape order:score", "landscape order:id", "id:#{name_of.keys.join(",")}", "landscape order:random"]
      wrong = (VIEWERS - [:anonymous]).product(searches).to_h do |viewer, tags|
        Rails.cache.clear
        CreatorVisibility.forget!
        params = { tags: tags, only: "id", limit: 200 }
        case viewer
        when :anonymous_unguarded
          reset!
          get posts_path(format: :json), params: params
        when :member_in_room then get_auth posts_path(format: :json), @member, params: params, headers: in_room
        else get_auth posts_path(format: :json), instance_variable_get("@#{viewer}"), params: params
        end
        assert_answered(viewer)
        got = response.parsed_body.pluck("id").filter_map { |id| name_of[id] }
        want = EXPECTED.select { |_name, viewers| viewers.include?(viewer) }.keys
        [[viewer, tags], { leaked: got - want, missing: tags.include?("random") ? [] : want - got }]
      end
      assert_empty wrong.reject { |_key, diff| diff.values.all?(&:empty?) }, "these searches answered these viewers wrongly"
    end

    # A bulk retag is not a viewer (Post.bulk_tag_match): it reaches the
    # posts every search hides, the row filter included.
    should "leave a bulk retag every post its query matches" do
      [User.anonymous, @member, @admin].each do |user|
        assert_empty @posts.values.map(&:id) - Post.bulk_tag_match("landscape", user).pluck(:id), user.name
      end
    end

    # The newest page a signed-out md5 ask is held to
    # (MembersOnly.anonymous_newest_ids) stands for the gallery's first page,
    # but is built apart from it, uncounted. The same posts, in both safe
    # modes, with every class among the newest:
    # the fillers deleted, and every class but :imageboard rated g so safe
    # mode has its own page to build.
    should "build the signed-out newest page as the gallery's first page shows it" do
      Post.where(id: @fillers.map(&:id)).update_all(is_deleted: true) # rubocop:disable Rails/SkipsModelValidations
      Post.where(id: @posts.except(:imageboard).values.map(&:id)).update_all(rating: "g") # rubocop:disable Rails/SkipsModelValidations
      visible = { false => %i[plain imageboard released old], true => %i[plain released old] }

      visible.each do |safe_mode, names|
        Rails.cache.clear
        CreatorVisibility.forget!
        gallery = CurrentUser.set(safe_mode: safe_mode) { PostSets::Post.new(nil, 1, user: User.anonymous).posts.map(&:id) }
        assert_equal @posts.values_at(*names).map(&:id).sort, gallery.sort, "fixture: the gallery's first page, safe mode #{safe_mode}"
        CreatorVisibility.forget!
        assert_equal gallery.to_set, MembersOnly.anonymous_newest_ids(safe_mode), "safe mode #{safe_mode}"
      end
    end
  end
end
