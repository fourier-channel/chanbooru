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
  POST_ID = /\bid="post_(\d+)"/

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
    decision = {
      "status" => response.status,
      "redirect" => (response.location if response.redirect?),
      "posts" => body.scan(POST_ID).flatten.map(&:to_i).uniq.sort,
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
  def payload_decisions(json)
    if json.key?("tags")
      {
        "tags" => json["tags"].to_h.transform_values { |list| Array(list).map { |t| t.is_a?(Hash) ? t["name"] : t }.compact.map(&:to_s).sort },
        "generation" => json["generation"].present?,
        "audience" => json["audience"],
        "quarantine" => json["quarantine"],
        "can_edit" => json["can_edit"],
        "candidates" => json["candidates"].to_h.keys.map(&:to_i).sort,
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
    surfaces = interface_surfaces(viewer).transform_values { |method, path, options| decide(method, path, **options.to_h) }
    surfaces.merge("session_keys" => session.to_hash.keys.sort - %w[session_id _csrf_token started_at])
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
  # the standing rules still hold it.
  SESSION_TRAIL_DOORS = %w[json_art_visit].freeze

  should "decide the same at every JSON door under both interfaces" do
    skip("recording") if InterfaceRecordingHelper.recording?
    paths = InterfaceRecordingHelper::VIEWERS.index_with { |viewer| InterfaceRecordingHelper::INTERFACES.map { |i| DECISIONS.join(i, "#{viewer}.json") } }
    missing = paths.values.flatten.reject(&:exist?).map { |path| path.relative_path_from(Rails.root).to_s }
    assert_empty(missing, "no recorded decisions to compare; fix: #{RECORD_FIX}")

    differing = paths.flat_map do |viewer, files|
      historical, modulation = files.map { |path| JSON.parse(path.read) }
      (historical.keys.grep(/\Ajson_/) - SESSION_TRAIL_DOORS).reject { |door| historical[door] == modulation[door] }.map { |door| "#{viewer} #{door}" }
    end
    assert_empty(differing, "a JSON door decided differently by interface")
  end
end
