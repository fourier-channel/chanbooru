# frozen_string_literal: true

# RECORD TODAY, BEFORE ANYTHING MOVES (Modulation interfaces, stage 1 step 1).
#
# Stage 1 carves the Modulation interface out of upstream's views into
# app/interfaces/modulation. Every later step claims "nothing a viewer sees
# changed"; this is what that claim is checked against: every surface the
# carve touches, rendered for every kind of viewer under BOTH interfaces, kept
# byte for byte as it drew on the day it was recorded
# (test/functional/interface_parity_test.rb), and what each viewer could reach
# of what a viewer must not (test/functional/interface_privacy_test.rb).
#
# A recording is only worth what its world is worth, so the world is fixed:
#
# - THE RULES ARE PRODUCTION'S. Under test, Danbooru.config relaxes a dozen
#   rules (members-only listings, default deny, banished withholding, ...) and
#   the box's own config/danbooru_local_config.rb, gitignored and different
#   per box, overrides more. A recording made through either is a recording of
#   a world nobody serves. So the config is the COMMITTED default
#   (Danbooru::Configuration, never CustomConfiguration and never the DANBOORU_*
#   environment), with every rule that branches on Rails.env read from that
#   same default as Rails.env "production" would answer it (PRODUCTION_RULES).
# - THE DATA IS SEEDED. Ids, names, md5s, sources and file keys are chosen,
#   never drawn: every sequence restarts at ID_BASE, time is frozen at EPOCH,
#   and both random sources (Ruby's and Postgres's) are reseeded before every
#   request, so random's flank and the layout's gift pick land the same way.
# - NOTHING IS NORMALISED beyond what changes per run by design: CSRF tokens,
#   nonces, asset digests, session ids, object ids and one attribute order
#   Ruby does not fix (NORMALISE).
#
# A recording is committed ASCII-only (org rule): the body is escaped
# injectively -- a backslash doubled, every byte outside printable ASCII,
# newline and tab written \u{hex} -- so two different pages never record the
# same. Bodies are stored once each, content-addressed under chunks/, and an
# index per (interface, viewer) names each surface's status and chunk.
module InterfaceRecordingHelper
  ROOT = Rails.root.join("test/files/interface_parity")
  CHUNKS = ROOT.join("chunks")
  INDEX = ROOT.join("index")
  RECORD_ENV = "INTERFACE_PARITY_RECORD"
  RECORD_FIX = "re-record with #{RECORD_ENV}=1 bin/rails test test/functional/interface_parity_test.rb " \
               "test/functional/interface_privacy_test.rb, then read `git diff test/files/interface_parity` and " \
               "commit it only if every change is one you meant"

  EPOCH = Time.utc(2026, 1, 15, 12, 0, 0)
  ID_BASE = 50_000

  INTERFACES = %w[historical modulation].freeze
  VIEWERS = %w[signed_out restricted member gold approver moderator admin owner creator].freeze

  CREATOR = "@pvcreator:41chan.net"
  SECRET_TAG = "pv_secret_prompt"
  PROMPT = "pv secret generation prompt"
  BANISHED = "pv_banished"
  FLAGGED = "pv_flagged"
  ARTIST = "pv_artist"
  BANNED_ARTIST = "pv_banned_artist"

  # Each rule Danbooru::Configuration answers by Rails.env, read from the
  # committed default as production. The identity proxy is the one exception:
  # production names its compose service, which resolves to nothing here, so
  # the proxy is this test's own peer -- the trust rule itself is unchanged.
  PRODUCTION_RULES = %i[
    enable_signup? matrix_accounts_from_identity? fourier_media_door default_experience_preset
    deleted_post_visibility_level retired_sections logout_page_retired? status_page_visibility_level
    extra_video_pix_fmts max_video_duration banished_posts_withheld? error_backtraces_public?
    unposted_media_assets_restricted? post_listings_members_only? anonymous_default_deny?
    posting_restricted_to_bots?
  ].freeze

  NORMALISE = [
    [/(<meta name="csrf-token" content=")[^"]*/, '\1CSRF'],
    [/(name="authenticity_token" (?:autocomplete="off" )?value=")[^"]*/, '\1CSRF'],
    [/(\bnonce=")[^"]*/, '\1NONCE'],
    # SessionObservation's digest of the session cookie: a session id, hashed.
    [/((?:&quot;|")digest(?:&quot;|"):(?:&quot;|"))[0-9a-f]+/, '\1SESSION'],
    # The Manage Session card's own cookies, raw: a session id, encrypted.
    [/("value":")[^"]*(","digest":"SESSION")/, '\1SESSION\2'],
    # The dtext editor names its file picker and image-size radios by the
    # component's object_id.
    [/((?:file-picker|image-size)-)\d+/, '\1OBJECT'],
    # The Modulation payload's quarantine tag_ids, {name => id} as Postgres
    # returned the rows -- the query has no ORDER BY -- in the page as JSON
    # or as &quot;-escaped JSON. Its entries sorted; every one is kept.
    [/tag_ids(?:"|&quot;):\{[^{}]*\}/, ->(run) { run.sub(/\{([^{}]*)\}\z/) { "{#{::Regexp.last_match(1).split(",").sort.join(",")}}" } }],
    # <body>'s data-current-user-is-<role> attributes, in User::Roles order,
    # which is User::Levels.constants: Ruby keeps a module's constants in a
    # symbol-id table, so that order follows what the process happened to
    # intern first and changes from run to run. Sorted; every value is kept.
    [/(?: data-current-user-is-[a-z-]+="[^"]*")+/, ->(run) { run.scan(/ data-current-user-is-[a-z-]+="[^"]*"/).sort.join }],
    [%r{(/packs/[^"' ]*?-)[0-9a-f]{8,}((?:\.chunk)?\.(?:js|css|map))}, '\1DIGEST\2'],
    [%r{(/packs/[^"' ]*?\.)[0-9a-f]{8,}(\.(?:js|css|map))}, '\1DIGEST\2'],
  ].freeze

  def self.recording? = ENV[RECORD_ENV].to_s == "1"

  # The committed default configuration, as production answers the rules
  # that branch on Rails.env.
  def self.production_rules
    @production_rules ||= begin
      production = Danbooru::Configuration.new
      env = Rails.env
      Rails.env = "production"
      PRODUCTION_RULES.index_with { |rule| production.public_send(rule) }
    ensure
      Rails.env = env
    end
  end

  def self.escape(text)
    utf8 = text.dup.force_encoding(Encoding::UTF_8)
    utf8 = utf8.scrub { |bytes| bytes.unpack("C*").map { |b| format("\\x{%02x}", b) }.join } unless utf8.valid_encoding?
    utf8.gsub("\\") { "\\\\" }.gsub(/[^\t\n\x20-\x7E]/) { |c| c.start_with?("\\x{") ? c : format("\\u{%x}", c.ord) }
  end

  def self.normalise(body)
    NORMALISE.reduce(body) do |text, (pattern, replacement)|
      replacement.is_a?(Proc) ? text.gsub(pattern) { replacement.call(::Regexp.last_match(0)) } : text.gsub(pattern, replacement)
    end
  end

  # The test's world, under production's rules and the committed config.
  def enter_recorded_world!(interface)
    @original_config = Danbooru.config
    config = Danbooru::Configuration.new
    Danbooru.config = config
    # test_helper's own stubs, re-applied to the new config object.
    storage_manager = StorageManager::Local.new(base_url: "https://www.example.com/data", base_dir: @temp_dir)
    config.stubs(:storage_manager).returns(storage_manager)
    config.stubs(:backup_storage_manager).returns(StorageManager::Null.new)
    config.stubs(:rate_limits_enabled?).returns(false)
    config.stubs(:autotagger_url).returns(nil)
    config.stubs(:iqdb_url).returns(nil)
    config.stubs(:captcha_site_key).returns(nil)

    InterfaceRecordingHelper.production_rules.each { |rule, value| config.stubs(rule).returns(value) }
    config.stubs(:default_experience_preset).returns(interface)
    config.stubs(:fourier_identity_proxy).returns("localhost")
    config.stubs(:gate3_matrix_posts_enforced?).returns(true)
    # MatrixUsernameValidator asks the homeserver whether a new name is
    # someone's Matrix username; here nobody's is.
    config.stubs(:fourier_media_origin).returns("https://chat.example")
    config.stubs(:fourier_matrix_profile_token).returns("syt_reader")
    Danbooru::Http.any_instance.stubs(:get).returns(stub(code: 404))
    Rails.application.config.x.stubs(:git_hash).returns("0000000000000000000000000000000000000000")

    travel_to(EPOCH)
    restart_sequences!
    Cache.clear
    CreatorVisibility.forget!
    build_world!
  end

  def leave_recorded_world!
    Danbooru.config = @original_config if @original_config
    # The stubbed proxy "localhost" leaves its addresses memoised on the
    # class: a later test in this worker whose proxy is elsewhere would see
    # its 127.0.0.1 peer as the proxy and honour the identity header.
    FourierIdentity.instance_variable_set(:@proxy_addresses, nil)
    restore_sequences!
  end

  # Sequences are not transactional: the test's rollback leaves them where the
  # recording took them. Rails truncates a test database's tables between runs
  # but keeps its sequences, and the seed's system user is created afresh from
  # them, so a sequence left behind ID_BASE hands out that user's id again
  # (users_pkey violations and User.last answering with the seed, fork-set
  # gate 2026-11-16). Each is put back where it stood, or where the recording
  # took it if that is further: never behind a value it has handed out.
  def restart_sequences!
    connection = ActiveRecord::Base.connection
    @sequence_marks ||= connection.select_rows("SELECT schemaname || '.' || sequencename, last_value FROM pg_sequences WHERE schemaname = 'public'")
    @sequence_marks.map(&:first).each do |sequence|
      connection.execute("SELECT setval(#{connection.quote(sequence)}, #{ID_BASE}, false)")
    end
  end

  def restore_sequences!
    return unless @sequence_marks

    connection = ActiveRecord::Base.connection
    @sequence_marks.each do |sequence, mark|
      connection.execute("SELECT setval(#{connection.quote(sequence)}, GREATEST(#{mark.to_i}, last_value), true) FROM #{sequence}")
    end
    @sequence_marks = nil
  end

  # Both random sources, the same before every request.
  def reseed!
    srand(1)
    ActiveRecord::Base.connection.execute("SELECT setseed(0.25)")
  end

  def media(seed)
    md5 = Digest::MD5.hexdigest("interface-parity-#{seed}")
    asset = create(:media_asset, md5: md5, pixel_hash: md5, file_ext: "png", image_width: 1200, image_height: 900, file_size: 123_456)
    # MediaAsset draws its file key at random on create, whatever it is given.
    asset.update_columns(file_key: format("pvkey%04d", seed)) # rubocop:disable Rails/SkipsModelValidations
    [md5, asset]
  end

  def make_post(seed, tags, rating: "s", **attributes)
    md5, asset = media(seed)
    as(@bot) do
      create(:post, md5: md5, media_asset: asset, file_ext: "png", image_width: 1200, image_height: 900, file_size: 123_456,
                    uploader: @bot, rating: rating, tag_string: tags, source: "https://example.com/pv/#{seed}", **attributes)
    end
  end

  # One of every thing the carve must keep drawing the same and keep from
  # the viewers who must not have it. Created in a fixed order, so every id
  # is fixed: the flanks of @art are @deleted (before) and @child (after).
  def build_world!
    @bot = create(:contributor_user, name: "tunnel")
    @viewers = {
      "restricted" => create(:restricted_user, name: "pv_restricted"),
      "member" => create(:user, name: "pv_member"),
      "gold" => create(:gold_user, name: "pv_gold"),
      "approver" => create(:approver_user, name: "pv_approver"),
      "moderator" => create(:moderator_user, name: "pv_moderator"),
      "admin" => create(:admin_user, name: "pv_admin"),
      "owner" => create(:owner_user, name: "pv_owner"),
      "creator" => create(:user, name: "pvcreator", matrix_id: CREATOR),
    }

    banish_tags!(BANISHED)
    flag_tags!(FLAGGED)
    as(@viewers["admin"]) do
      create(:artist, name: ARTIST)
      create(:artist, name: BANNED_ARTIST, is_banned: true)
    end

    @older = make_post(1, "#{ARTIST} landscape scenery")
    @deleted = make_post(2, "#{ARTIST} landscape")
    @art = make_post(3, "#{ARTIST} landscape scenery sky", rating: "g")
    @child = make_post(4, "#{ARTIST} landscape", parent_id: @art.id)
    @jailed = make_post(5, "landscape #{BANISHED}")
    @closed = make_post(6, "#{ARTIST} landscape")
    @flagged = make_post(7, "landscape #{FLAGGED}")
    @banned = make_post(8, "#{BANNED_ARTIST} landscape")

    @deleted.delete!("pv ordinary deletion", user: @viewers["admin"])

    [@older, @deleted, @art, @child, @closed].each do |post|
      FourierPostCreator.create!(post: post, mxid: CREATOR, recorded_by: @bot.id)
    end
    FourierTagSource.record_partition!(@art, { creator: [SECRET_TAG], auto: @art.tag_array }, @bot)
    FourierGenerationMetadata.create!(md5: @art.md5, raw_md5: Digest::MD5.hexdigest("pv raw"), source: "matrix", poster: CREATOR,
                                      fields: { "png:parameters" => PROMPT })

    @gallery = CreatorGallery.create!(slug: "pvcreator", matrix_id: CREATOR, title: "PV Creator", user: @viewers["creator"],
                                      promoted_at: EPOCH - 1.day)
    CreatorPostAudience.set!(@closed, gallery: @gallery, audience: "private", by: @viewers["creator"])
    # A wiki page with a strip (Modulation families): on "scenery", which no
    # other surface searches, so no recording made before it moves. Last, so
    # no id above it moves either.
    as(@viewers["admin"]) { create(:wiki_page, title: "scenery", body: "pv scenery wiki") }
    # A taken-down post (Post#banblocked? below Moderator), which no metatag
    # names: the gallery omits it and the window's rows leave it out
    # (PostSets::Post#window_query), so no card and no cursor names it.
    # After the wiki page, so no id above it moves.
    @taken_down = make_post(9, "#{ARTIST} landscape", is_taken_down: true)
    CreatorVisibility.forget!
    [@older, @deleted, @art, @child, @jailed, @closed, @flagged, @banned, @taken_down].each(&:reload)
  end

  # A fresh browser for `viewer`: signed in to the booru for a booru viewer,
  # carrying the creator's verified Matrix identity for the creator (whose
  # linked account it signs in), nothing for a signed-out visitor.
  def become(viewer)
    reset!
    @identity = (viewer == "creator") ? { "X-Fourier-Identity" => CREATOR } : {}
    login_as(@viewers.fetch(viewer)) unless %w[signed_out creator].include?(viewer)
  end

  def fetch(method, path, headers: {}, **options)
    reseed!
    send(method, path, headers: @identity.to_h.merge(headers), **options)
    response
  end

  # surface => [method, path, options]. Paths are built from the world's
  # fixed ids, so a surface is the same request on every run.
  def interface_surfaces(viewer)
    art = @art.id
    list = {
      "home" => [:get, "/"],
      "landing_slides" => [:get, "/landing/slides"],
      "posts" => [:get, "/posts"],
      "posts_tag_search" => [:get, "/posts?tags=landscape"],
      "posts_banished_search" => [:get, "/posts?tags=#{BANISHED}"],
      "posts_banned_artist" => [:get, "/posts?tags=#{BANNED_ARTIST}"],
      "posts_window" => [:get, "/posts?variant=window"],
      "posts_random" => [:get, "/posts/random"],
      "post_art" => [:get, "/posts/#{art}"],
      "post_child" => [:get, "/posts/#{@child.id}"],
      "post_deleted" => [:get, "/posts/#{@deleted.id}"],
      "post_jailed" => [:get, "/posts/#{@jailed.id}"],
      "post_closed" => [:get, "/posts/#{@closed.id}"],
      "post_flagged" => [:get, "/posts/#{@flagged.id}"],
      "post_banned_artist" => [:get, "/posts/#{@banned.id}"],
      "post_tooltip" => [:get, "/posts/#{art}?variant=tooltip&preview=true"],
      "post_closed_tooltip" => [:get, "/posts/#{@closed.id}?variant=tooltip&preview=true"],
      "stray_posts_tooltip" => [:get, "/posts?variant=tooltip"],
      "stray_login_tooltip" => [:get, "/login?variant=tooltip"],
      "login" => [:get, "/login"],
      "gallery" => [:get, "/creators/pvcreator"],
      "gallery_identity" => [:get, "/creators/pvcreator?view=identity"],
      "tags" => [:get, "/tags"],
      "not_found" => [:get, "/posts/999999999"],
      "retired_section" => [:get, "/comments"],
      "json_art" => [:get, "/posts/#{art}/modulation"],
      "json_art_visit" => [:get, "/posts/#{art}/modulation?visit=1"],
      "json_art_prefetch" => [:get, "/posts/#{art}/modulation?prefetch=1"],
      "json_art_opened" => [:get, "/posts/#{art}/modulation?opened=1"],
      "json_closed_opened" => [:get, "/posts/#{@closed.id}/modulation?opened=1"],
      "json_jailed" => [:get, "/posts/#{@jailed.id}/modulation"],
      "json_deleted" => [:get, "/posts/#{@deleted.id}/modulation"],
      "json_creator_activity" => [:get, "/modulation/creator_activity?tags=#{ARTIST},#{BANISHED}"],
      "json_session_status" => [:get, "/modulation/session_status"],
      "json_session_tokens" => [:post, "/modulation/session_tokens"],
      # The subject pages Modulation draws (Modulation families). Each strip
      # is on a tag every secret case of the world carries -- deleted,
      # banished, closed, banned -- so the privacy rules read its cards.
      "artist_show" => [:get, "/artists/#{Artist.find_by!(name: ARTIST).id}"],
      "artist_banned" => [:get, "/artists/#{Artist.find_by!(name: BANNED_ARTIST).id}"],
      "artist_show_or_new" => [:get, "/artists/show_or_new?name=pv_nobody"],
      "wiki_show" => [:get, "/wiki_pages/scenery"],
      "wiki_landscape" => [:get, "/wiki_pages/landscape"],
      "wiki_banned_artist" => [:get, "/wiki_pages/#{BANNED_ARTIST}"],
      "wiki_missing" => [:get, "/wiki_pages/nonesuch"],
      "tag_show" => [:get, "/tags/#{Tag.find_by!(name: "landscape").id}"],
      "explore_popular" => [:get, "/explore/posts/popular"],
    }
    # GoodJob's own dashboard is a gem's page, drawn from live job rows; what
    # the carve must keep is who is let in, which a signed-out visitor shows.
    list["good_job"] = [:get, "/good_job"] if viewer == "signed_out"
    list
  end

  # A redirect is recorded as where it goes, never as the body Rails writes.
  def draw(method, path, **options)
    fetch(method, path, **options)
    body = response.redirect? ? "Location: #{response.location}\n" : response.body
    [response.status, body]
  end

  # --- the store ----------------------------------------------------------

  def chunk_path(sha) = CHUNKS.join("#{sha}.txt")
  def index_path(interface, viewer) = INDEX.join(interface, "#{viewer}.txt")

  # @param drawn [Hash{String => [Integer, String]}] surface => [status, body]
  def assert_matches_recording(interface, viewer, drawn)
    entries = drawn.transform_values do |status, body|
      text = InterfaceRecordingHelper.escape(InterfaceRecordingHelper.normalise(body.to_s))
      [status, Digest::SHA256.hexdigest(text).first(24), text]
    end

    if InterfaceRecordingHelper.recording?
      write_recording(interface, viewer, entries)
      return
    end

    path = index_path(interface, viewer)
    flunk("no recording for #{interface}/#{viewer} (#{path.relative_path_from(Rails.root)}); fix: #{RECORD_FIX}") unless path.exist?

    recorded = path.readlines(chomp: true).to_h do |line|
      surface, status, sha = line.split
      [surface, [status.to_i, sha]]
    end

    problems = (recorded.keys - entries.keys).map { |surface| "#{surface}: recorded, but no longer drawn" }
    (entries.keys - recorded.keys).each { |surface| problems << "#{surface}: drawn, but never recorded" }
    (entries.keys & recorded.keys).each do |surface|
      status, sha, text = entries[surface]
      want_status, want_sha = recorded[surface]
      chunk = chunk_path(want_sha)
      if !chunk.exist?
        problems << "#{surface}: its recording #{chunk.relative_path_from(Rails.root)} is missing"
      elsif status != want_status
        problems << "#{surface}: answered #{status}, recorded #{want_status}"
      elsif sha != want_sha
        problems << "#{surface}: #{first_difference(chunk.read, text)}"
      end
    end

    assert(problems.empty?, "#{interface}/#{viewer} no longer draws as recorded:\n  #{problems.join("\n  ")}\nfix: if the change is " \
                            "a bug, fix it; if it is meant, #{RECORD_FIX}")
  end

  # The first differing line, shown around its first differing character: a
  # page line can run to kilobytes, and its start is rarely where it changed.
  def first_difference(want, got)
    want_lines = want.split("\n", -1)
    got_lines = got.split("\n", -1)
    index = want_lines.zip(got_lines).index { |a, b| a != b } || [want_lines.size, got_lines.size].min
    a = want_lines[index].to_s
    b = got_lines[index].to_s
    column = (0...[a.size, b.size].max).find { |c| a[c] != b[c] }.to_i
    from = [column - 80, 0].max
    "first difference at line #{index + 1}, column #{column + 1}\n    recorded: #{a[from, 240].inspect}\n    drawn:    #{b[from, 240].inspect}"
  end

  def write_recording(interface, viewer, entries)
    FileUtils.mkdir_p(CHUNKS)
    entries.each_value do |_status, sha, text|
      chunk = chunk_path(sha)
      next if chunk.exist?

      temp = CHUNKS.join(".#{sha}.#{Process.pid}")
      File.write(temp, text)
      File.rename(temp, chunk)
    end
    path = index_path(interface, viewer)
    FileUtils.mkdir_p(path.dirname)
    File.write(path, entries.sort.map { |surface, (status, sha, _)| "#{surface} #{status} #{sha}\n" }.join)
    assert(path.exist?, "the recording #{path} was not written")
  end
end
