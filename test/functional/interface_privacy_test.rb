# frozen_string_literal: true

require "test_helper"

# What each viewer can REACH, recorded today, on the same surfaces and the
# same world the parity recording draws (interface_recording_helper.rb).
#
# The parity test says a page changed; this says whether a viewer's reach
# did, in words a reader can judge: which posts a surface lists, whether it
# answers at all, which of the world's secrets appear in it (the creator's
# private tag, the generation prompt, the banished and flagged names, the
# banned artist), what the post payload decides for this viewer (its tag
# buckets, generation, audience, quarantine, edit right, flank candidates,
# notices), what the session holds afterwards, and which admin views were
# logged. A carve that keeps every byte keeps all of these; one that moves a
# check can keep most bytes and lose one of these, and this names it.
#
# Beside the recording, the rules that hold whatever was recorded
# (assert_standing_rules): a recording can only say "as before", and a
# before that was already wrong would pass.
class InterfacePrivacyTest < ActionDispatch::IntegrationTest
  include InterfaceRecordingHelper
  include TagQuarantineTestHelper

  DECISIONS = InterfaceRecordingHelper::ROOT.join("decisions")
  POST_ID = /\bid="post_(\d+)"|<a class="modgal-card[^"]*"[^>]*?\bdata-id="(\d+)"/
  # A post id a page carries as a place rather than a card: a gallery
  # card's data-key and an anchor= cursor in a pager href (PostNeighbors::
  # Seek's "<id>~<key>"). Read for the standing rules only, not recorded.
  CURSOR_ID = /\bdata-key="(\d+)~|[?&;]anchor=(\d+)(?:~|%7E)/
  # The surfaces whose cards the id reader is witnessed on: the post index
  # (article or gallery card) and the strips of the subject pages.
  CARD_SURFACES = %w[posts artist_show wiki_show explore_popular].freeze
  # Paging, which no surface above reaches: the world holds fewer posts than
  # a page. Under a box of two (PostSets::Post::WINDOW_SLOTS) and limit=2,
  # each of these is fetched, then the page its own next link leads to, as
  # "<surface>_next" -- the second page a visitor walks to, cursor and all.
  # The newest rows are the banned child, the taken-down post and the
  # banned post, so a page whose rows are not the listed rows (classic's
  # index, either popular) fetches them and draws fewer than two; the
  # walk crosses them on every interface.
  # The next link is the paginator's (a.paginator-next) or the gallery's
  # (a.modgal-page[rel=next]), never a bare rel=next: popular's date
  # navigation is #paginator-next, which goes to the next DAY.
  PAGED_SURFACES = {
    "posts_paged" => "/posts?limit=2",
    "posts_tag_search_paged" => "/posts?tags=landscape&limit=2",
    "explore_popular_paged" => "/explore/posts/popular?limit=2",
  }.freeze
  NEXT_LINK = "a.paginator-next[href], a.modgal-page[rel=next][href]"
  # The cards a page shows, as against draws: the gallery draws a chunk and
  # marks the cards outside its box is-off.
  BOX_CARDS = "article[id^='post_'], a.modgal-card[data-id]:not(.is-off)"

  def secrets
    { "creator_private_tag" => SECRET_TAG, "generation_prompt" => PROMPT, "banished_name" => BANISHED,
      "flagged_name" => FLAGGED, "banned_artist" => BANNED_ARTIST }
  end

  def admin_views = ModAction.where(category: "creator_hidden_post_view").count

  # @return [Hash] one surface's decisions
  def decide(method, path, **options)
    logged_before = admin_views
    fetch(method, path, **options)
    body = response.body.to_s
    (@bodies ||= {})[@deciding] = body if @deciding
    decision = {
      "status" => response.status,
      "redirect" => (response.location if response.redirect?),
      "posts" => body.scan(POST_ID).flatten.compact.map(&:to_i).uniq.sort,
      "secrets" => secrets.select { |_, text| body.include?(text) }.keys,
      "blacklist_box" => body.include?('id="blacklist-box"'),
      "admin_views_logged" => admin_views - logged_before,
    }
    json = begin
      (response.media_type == "application/json" && response.successful?) ? response.parsed_body : nil
    rescue JSON::ParserError
      nil
    end
    decision["payload"] = payload_decisions(json) if json.is_a?(Hash)
    decision.compact
  end

  # What a JSON door decided for this viewer, reduced to the parts that are
  # a decision rather than a drawing.
  #
  # The flank candidates are split by who offered them. Random's are the
  # session's RandomTrail (PostSurface#random_neighbours), which Modulation's
  # post pages extend and classic's do not, so the same door asks the trail
  # a different question per interface; the keyset modes are not session
  # state. An id any keyset mode offers counts as keyset, and an id no
  # preset names stays in "candidates", so nothing unexplained is set aside.
  def payload_decisions(json)
    if json.key?("tags")
      candidates = json["candidates"].to_h.keys.map(&:to_i).sort
      by_random = Array(json["presets"]).partition { it["key"] == "random" }.map { |presets| presets.flat_map { (it["prev_candidates"].to_a + it["next_candidates"].to_a).map { |ref| ref["id"].to_i } } }
      random_only = ((by_random[0] - by_random[1]) & candidates).sort
      {
        "tags" => json["tags"].to_h.transform_values { |list| Array(list).map { |t| t.is_a?(Hash) ? t["name"] : t }.compact.map(&:to_s).sort },
        "generation" => json["generation"].present?,
        "audience" => json["audience"],
        "quarantine" => json["quarantine"],
        "can_edit" => json["can_edit"],
        "candidates" => candidates - random_only,
        "random_candidates" => random_only,
        "notices" => json["notices"],
        "status" => json["status"],
        "logs_admin_view" => json["logs_admin_view"],
        "moderation" => json["moderation"],
      }
    else
      { "keys" => json.keys.sort }
    end
  end

  def decisions_for(viewer)
    become(viewer)
    @bodies = {}
    surfaces = interface_surfaces(viewer).to_h do |surface, (method, path, options)|
      @deciding = surface
      [surface, decide(method, path, **options.to_h)]
    end
    surfaces.merge!(paged_decisions)
    @deciding = nil
    surfaces.merge("session_keys" => session.to_hash.keys.sort - %w[session_id _csrf_token started_at])
  end

  # PAGED_SURFACES, each fetched and then followed to its next page.
  def paged_decisions
    small_window do
      PAGED_SURFACES.each_with_object({}) do |(surface, path), decided|
        @deciding = surface
        decided[surface] = decide(:get, path)
        href = Nokogiri::HTML5(@bodies[surface]).at_css(NEXT_LINK)&.[]("href")
        next if href.blank?

        @deciding = "#{surface}_next"
        decided[@deciding] = decide(:get, href)
      end
    end
  end

  # A box of two from a chunk of four, so three listed posts span two pages.
  def small_window(&)
    stub_const(PostSets::Post, :WINDOW_SLOTS, 2) do
      stub_const(PostSets::Post, :WINDOW_CHUNK, 4) do
        stub_const(PostSets::Post, :WINDOW_CHUNK_MAX, 4, &)
      end
    end
  end

  def box_ids(body)
    Nokogiri::HTML5(body).css(BOX_CARDS).map { |card| (card["data-id"] || card["id"].delete_prefix("post_")).to_i }
  end

  # The rules this recording must never be the only witness to.
  def assert_standing_rules(viewer, decided)
    surfaces = decided.except("session_keys")
    visible_ids = surfaces.values.flat_map { |d| d["posts"] }.uniq

    # A post a viewer may not see is not listed, linked or answered for them.
    unless %w[admin owner].include?(viewer)
      assert_not_includes(visible_ids, @deleted.id, "#{viewer} was shown the deleted post")
      assert_not_includes(visible_ids, @jailed.id, "#{viewer} was shown the jailed post")
      %w[post_deleted post_jailed json_deleted json_jailed].each do |surface|
        assert_equal(404, surfaces[surface]["status"], "#{surface} answered #{viewer} with #{surfaces[surface]["status"]}, not 404")
      end
    end

    # The creator's private audience: not for a signed-out visitor, a
    # Restricted or a Member account.
    if %w[signed_out restricted member].include?(viewer)
      assert_not_includes(visible_ids, @closed.id, "#{viewer} was shown the post its creator hid")
      assert_equal(404, surfaces["json_closed_opened"]["status"], "the hidden post's JSON door answered #{viewer}")
    end

    # Every post any surface lists for a viewer is one that exists for them
    # in a list (PostPreviewComponent.listed?: not banned or taken down past
    # their level, not banished, not hidden beyond deletion; deleted is the
    # rule above). Not "visible": a listed post whose image is withheld may
    # keep a designed gated face, which names an id the viewer may list. The
    # ids are read from the cards themselves, so a card of any face counts.
    # The leak this names (2026-11-18): Modulation's gallery drew a gated
    # card for the banned post, so a Member's page carried its id.
    #
    # The places a page carries count as listing too (CURSOR_ID): a cursor
    # names a post's id and its sort key, so a pager whose prev or next is
    # built from a row the cards omit names that post as surely as a card.
    #
    # So do a JSON door's flank candidates, keyset and random alike: each is
    # a post the viewer is offered to step to. The cross-interface check
    # sets "random_candidates" aside (it compares two different session
    # trails), so this is the rule that holds them.
    user = (viewer == "signed_out") ? User.anonymous : @viewers.fetch(viewer)
    cursor_ids = @bodies.transform_values { |body| body.scan(CURSOR_ID).flatten.compact.map(&:to_i).uniq }
    flank_ids = surfaces.transform_values { |d| d["payload"].is_a?(Hash) ? d["payload"]["candidates"].to_a | d["payload"]["random_candidates"].to_a : [] }
    named = surfaces.to_h { |surface, d| [surface, (d["posts"].to_a | cursor_ids[surface].to_a | flank_ids[surface])] }
    world = Post.where(id: named.values.flatten.uniq).index_by(&:id)
    unlistable = named.filter_map do |surface, ids|
      ids = ids.reject { |id| world[id] && PostPreviewComponent.listed?(world[id], user, show_deleted: true) }
      "#{surface}: #{ids.join(", ")}" if ids.any?
    end
    assert_empty(unlistable, "#{viewer} was listed posts that do not exist for them, as cards or as cursors; fix: the interface draws its list through PostPreviewComponent.listed? (GallerySurface#posts, PostStripSurface#posts), and the window's rows are the listed rows (PostSets::Post#window_query)")
    named_ids = named.values.flatten.uniq
    assert_not_includes(named_ids, @banned.id, "#{viewer} (below Approver) was listed the banned post") unless user.is_approver?
    assert_not_includes(named_ids, @taken_down.id, "#{viewer} (below Moderator) was listed the taken-down post") unless user.is_moderator?
    assert_not_includes(named_ids, @banned_child.id, "#{viewer} (below Approver) was listed the banned child of the art post") unless user.is_approver?
    # ... and the flank reader is live: from Member up the art post's JSON
    # door offers the older post as a flank, so an empty read is a broken
    # reader, not a clean page.
    unless %w[signed_out restricted].include?(viewer)
      assert_includes(flank_ids["json_art"], @older.id, "#{viewer}'s json_art offered no flank candidate the rule above could read; fix: payload_decisions reads json[\"candidates\"] and the presets' prev/next_candidates")
    end
    # ... and the fixture is live: Modulation's post view draws @art's family,
    # so from Approver up the banned child is a card there. Without this the
    # rule above passes when no family is drawn at all.
    if user.is_approver? && Danbooru.config.default_experience_preset == "modulation"
      assert_includes(surfaces.dig("post_art", "posts").to_a, @banned_child.id, "#{viewer} met no family card for the banned child on the art post; fixture: ModulationPostFamilyComponent draws @art's children")
    end

    # The id reader above is the witness of every rule on ids: a page whose
    # cards it cannot read would pass them all with an empty list. On the
    # post index and the subject pages' strips, which list the world's
    # ordinary posts to every signed-in viewer, the ids it read are as many
    # as the cards drawn, and not none.
    if viewer != "signed_out"
      CARD_SURFACES.each do |surface|
        next unless surfaces.dig(surface, "status") == 200

        cards = @bodies.fetch(surface).scan(/<article\b[^>]*\bid="post_\d+"|<a class="modgal-card\b/).size
        read = surfaces[surface]["posts"].to_a

        assert_operator(cards, :>, 0, "#{surface} drew no cards for #{viewer}; fixture: the world's ordinary posts are listed to every signed-in viewer")
        assert_equal(cards, read.size, "#{surface} drew #{cards} cards for #{viewer} and POST_ID read #{read.size} ids; fix: POST_ID must read every card's id, or every rule on ids passes blind")
      end

      # And the cursor reader: every gallery card's data-key is read.
      keys = @bodies.fetch("posts").scan(/<a class="modgal-card[^"]*"[^>]*?\bdata-key="\d+~/).size
      assert_operator(keys, :>, 0, "posts drew no keyed cards for #{viewer} under Modulation; fixture: the gallery window keys every card for a viewer who may browse") if Danbooru.config.default_experience_preset == "modulation" && user.can_browse_freely?
      assert_equal(keys, cursor_ids["posts"].size, "posts drew #{keys} keyed cards for #{viewer} and CURSOR_ID read #{cursor_ids["posts"].size}; fix: CURSOR_ID must read every data-key, or the rule on cursors passes blind")
    end

    # Paging: a viewer who may browse past the first page walks from the
    # first page of each paged surface to a second, and the two show no
    # post in common. The rules above already hold both pages' cards and
    # cursors (a cursor in page one's next link names the post page two
    # starts at), so this is their witness that a second page was read.
    # Below the browsing tier (User#can_browse_freely?: signed out,
    # Restricted) the list is one page with no next link; the recording
    # holds that. How many cards a page shows is fixed only where its rows
    # are the listed rows -- Modulation's gallery box (PostSets::Post#
    # window_query) -- so only there is a page of two two cards; elsewhere
    # banned and taken-down rows are fetched and not drawn.
    if user.can_browse_freely?
      PAGED_SURFACES.each_key do |surface|
        first, second = surfaces[surface], surfaces["#{surface}_next"]
        assert_equal(200, first&.dig("status"), "#{surface} answered #{viewer} with #{first&.dig("status").inspect}")
        assert_equal(200, second&.dig("status"), "#{surface} led #{viewer} to no second page (#{second&.dig("status").inspect}); fixture: the world holds more rows than a page of two; fix: the page draws a next link (#{NEXT_LINK})")

        shown = box_ids(@bodies.fetch(surface))
        shown_next = box_ids(@bodies.fetch("#{surface}_next"))
        assert_operator((shown | shown_next).size, :>, 0, "#{surface} showed #{viewer} no posts on either page; fixture: the world's ordinary posts are listed to every viewer who may browse")
        assert_empty(shown & shown_next, "#{surface}'s second page showed #{viewer} posts the first page showed")
        if @bodies.fetch(surface).include?('class="modgal-grid')
          assert_equal(2, shown.size, "#{surface}'s gallery box showed #{viewer} #{shown.size} posts in a box of two; fix: the window's rows are the listed rows (PostSets::Post#window_query) and the grid reads the box per request (GridComponent#off?)")
        end
      end
    end

    # A signed-out visitor never meets a creator's secret.
    if viewer == "signed_out"
      leaked = surfaces.select { |_, d| d["secrets"].intersect?(%w[creator_private_tag generation_prompt]) }.keys
      assert_empty(leaked, "a signed-out visitor met the creator's private tag or prompt on: #{leaked.join(", ")}")
    end

    # Q2's log (CreatorVisibility.log_admin_view): an admin -- the owner is
    # one -- opening a hidden post logs exactly one view, on its page and on
    # the Modulation viewer's ?opened=1; its tooltip, a listing and a plain
    # fetch of the payload log none; nobody else logs.
    logged = surfaces.select { |_, d| d["admin_views_logged"].to_i > 0 }.transform_values { |d| d["admin_views_logged"] }
    if %w[admin owner].include?(viewer)
      assert_equal({ "post_closed" => 1, "json_closed_opened" => 1 }, logged, "#{viewer} views logged per surface")
    else
      assert_equal({}, logged, "#{viewer} logged an admin view")
    end

    # Every full page keeps the blacklist box (upstream's blacklist runs on it).
    # Not the fragments drawn with no layout: the tooltips, the gallery
    # window's chunk and the landing slides.
    pages = surfaces.select { |_, d| d["status"] == 200 && !d.key?("payload") && !d["redirect"] }
    fragments = %w[post_tooltip post_closed_tooltip stray_posts_tooltip stray_login_tooltip posts_window landing_slides]
    missing = pages.reject { |_, d| d["blacklist_box"] }.keys - fragments
    assert_empty(missing, "these pages lost #blacklist-box for #{viewer}")
  end

  def assert_matches_decisions(interface, viewer, decided)
    path = DECISIONS.join(interface, "#{viewer}.json")
    text = "#{JSON.pretty_generate(decided)}\n"
    if InterfaceRecordingHelper.recording?
      FileUtils.mkdir_p(path.dirname)
      File.write(path, text)
      assert(path.exist?)
      return
    end

    flunk("no recorded decisions for #{interface}/#{viewer} (#{path.relative_path_from(Rails.root)}); fix: #{RECORD_FIX}") unless path.exist?
    recorded = JSON.parse(path.read)
    changed = (recorded.keys | decided.keys).filter_map do |surface|
      next if recorded[surface] == JSON.parse(decided[surface].to_json)

      "#{surface}:\n      recorded: #{recorded[surface].to_json}\n      decided:  #{decided[surface].to_json}"
    end
    assert(changed.empty?, "what #{viewer} can reach under #{interface} changed:\n  #{changed.join("\n  ")}\n" \
                           "fix: a viewer reaching more or less is a privacy change -- if it is a bug, fix it; if it is meant, #{RECORD_FIX}")
  end

  setup { @original_config = Danbooru.config }
  teardown { leave_recorded_world! }

  InterfaceRecordingHelper::INTERFACES.each do |interface|
    InterfaceRecordingHelper::VIEWERS.each do |viewer|
      should "give #{viewer} under #{interface} the reach it had when recorded" do
        enter_recorded_world!(interface)
        decided = decisions_for(viewer)
        assert_standing_rules(viewer, decided)
        assert_matches_decisions(interface, viewer, decided)
      end
    end
  end

  # The JSON doors are the same code under both interfaces: what they decide
  # may not depend on which interface the viewer browses with. Not the
  # ?visit=1 door: it answers from the session's random trail, which
  # Modulation's post pages extend and classic's do not, so the two
  # recordings ask it different questions. Each interface's recording and
  # the standing rules still hold it. Every other door's random flank is set
  # aside the same way, by name ("random_candidates", payload_decisions).
  SESSION_TRAIL_DOORS = %w[json_art_visit].freeze

  should "decide the same at every JSON door under both interfaces" do
    skip("recording") if InterfaceRecordingHelper.recording?
    paths = InterfaceRecordingHelper::VIEWERS.index_with { |viewer| InterfaceRecordingHelper::INTERFACES.map { |i| DECISIONS.join(i, "#{viewer}.json") } }
    missing = paths.values.flatten.reject(&:exist?).map { |path| path.relative_path_from(Rails.root).to_s }
    assert_empty(missing, "no recorded decisions to compare; fix: #{RECORD_FIX}")

    differing = paths.flat_map do |viewer, files|
      historical, modulation = files.map { |path| JSON.parse(path.read) }
      keyset = ->(decision) { decision.is_a?(Hash) && decision["payload"].is_a?(Hash) ? decision.merge("payload" => decision["payload"].except("random_candidates")) : decision }
      (historical.keys.grep(/\Ajson_/) - SESSION_TRAIL_DOORS).reject { |door| keyset.call(historical[door]) == keyset.call(modulation[door]) }.map { |door| "#{viewer} #{door}" }
    end
    assert_empty(differing, "a JSON door decided differently by interface")
  end
end
