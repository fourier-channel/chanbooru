require "test_helper"

# TIMED LINKS, the booru's half (CreatorTimedLinks; fourier-basis
# docs/design/CREATOR_REACH.md sec 2): what it sends sampling, once, when a
# link is made, what it refuses before asking, and that every way sampling
# can fail is a Failure naming its fix -- never a silent empty list.
class CreatorTimedLinksTest < ActiveSupport::TestCase
  include TimedLinksHelper

  setup do
    @owner = create(:user)
    @gallery = CreatorGallery.create!(slug: "maple", matrix_id: "@maple:41chan.net", title: "Maple", user: @owner)
    @http = FakeSamplingHttp.new
    @links = timed_links(@gallery, @http)
    @noon = Time.zone.parse("2026-11-08 12:00")
  end

  def picture(**attrs)
    create(:post, md5: SecureRandom.hex(16), **attrs)
  end

  context "unset config" do
    should "refuse loudly and ask nothing" do
      [[nil, KEY], [BASE, nil], ["", ""]].each do |url, key|
        links = CreatorTimedLinks.new(@gallery, url: url, key: key, http: @http)
        assert_not links.configured?
        error = assert_raises(CreatorTimedLinks::Failure) { links.list }
        assert_match(/DANBOORU_FOURIER_SAMPLING_CREATOR_KEY/, error.message)
      end
      assert_empty @http.calls
    end
  end

  context "list" do
    should "ask for this gallery's links with the key and read them newest first" do
      old = link_row(hash: "b" * 32, title: "Old", created: 2.days.ago)
      new = link_row(hash: "c" * 32, title: "New", created: 1.hour.ago)
      @http.answer(listing([old, new], max_live: 5, max_days: 30))

      got = @links.list
      call = @http.calls.sole
      assert_equal [:get, "#{BASE}/api/publications"], [call[:method], call[:url]]
      assert_equal({ owner: @gallery.id }, call[:options][:params])
      assert_equal KEY, call[:headers]["X-Fourier-Creator-Key"]
      assert_equal %w[New Old], got.links.map(&:title)
      assert_equal "https://sample.example.net/p/#{"c" * 32}", got.links.first.url
      assert_equal [5, 30], [got.max_live, got.max_days]
    end

    should "be a Failure for every wrong answer, each naming its fix" do
      {
        [{ error: "no" }, 401] => /FS_CREATOR_LINK_KEY must hold the same value/,
        [{ error: "creator links are off" }, 503] => /creator links off/,
        ["", 598] => /did not answer \(598\).*firewall/,
        ["<html>", 200] => /not JSON/,
        [[1, 2], 200] => /not an object/,
        [{ ok: true, links: "x", max_live: 5, max_days: 30 }, 200] => /links that are not a list/,
        [{ ok: true, links: [] }, 200] => /FS_CREATOR_LINK_MAX_LIVE/,
        [listing([{ hash: "a" * 32, url: "http://plain/p/x", createdAt: 1, expiresAt: 2 }]), 200] => /https url.*FS_PUBLISHED_BASE/,
      }.each do |(body, status), message|
        @http.answer(body, status: status)
        error = assert_raises(CreatorTimedLinks::Failure, "#{status} #{body}") { @links.list }
        assert_match(message, error.message)
      end
    end
  end

  context "latest_end_date" do
    should "be the last day whose end falls within the limit" do
      assert_equal Date.new(2026, 12, 7), CreatorTimedLinks.latest_end_date(30, now: @noon)
      # Made in the day's last instant, the link may run to the end of day 30 exactly.
      assert_equal Date.new(2026, 12, 8), CreatorTimedLinks.latest_end_date(30, now: @noon.end_of_day)
      assert_operator CreatorTimedLinks.latest_end_date(30, now: @noon).in_time_zone.end_of_day, :<=, @noon + 30.days
    end
  end

  context "create" do
    should "send the posts once, in order, with the gallery as owner and an end at the end of the day picked" do
      a = picture(file_ext: "png", image_width: 800, image_height: 600, rating: "g")
      b = picture(file_ext: "mp4", image_width: 1920, image_height: 1080, rating: "e")
      @http.answer({ ok: true, link: link_row(title: "October", posts: 2) })

      link = @links.create(posts: [b, a], title: "  October\n set ", ends_on: Date.new(2026, 11, 30), max_days: 30, now: @noon)
      call = @http.calls.sole
      body = call[:options][:json]
      assert_equal [:post, "#{BASE}/api/publish"], [call[:method], call[:url]]
      assert_equal KEY, call[:headers]["X-Fourier-Creator-Key"]
      assert_equal "creator", body[:kind]
      assert_equal @gallery.id.to_s, body[:owner]
      assert_equal "Maple", body[:owner_name]
      assert_equal "October set", body[:title]
      assert_equal (Time.zone.parse("2026-11-30").end_of_day - @noon).ceil, body[:expires_seconds]
      assert_equal [{ id: b.id, md5: b.md5, ext: "mp4", w: 1920, h: 1080, rating: "e" },
                    { id: a.id, md5: a.md5, ext: "png", w: 800, h: 600, rating: "g" }], body[:posts]
      assert_equal "October", link.title
    end

    should "refuse what cannot be made without asking" do
      ok = picture
      cases = {
        [[], Date.new(2026, 11, 20)] => /at least one/,
        [Array.new(25) { ok }, Date.new(2026, 11, 20)] => /at most 24 posts; you picked 25/,
        [[ok], Date.new(2026, 11, 7)] => /from today on/,
        [[ok], Date.new(2026, 12, 8)] => /on or before 2026-12-07: a timed link lives at most 30 days/,
        [[picture(is_deleted: true)], Date.new(2026, 11, 20)] => /is deleted/,
        [[picture(file_ext: "zip")], Date.new(2026, 11, 20)] => /\.zip file/,
      }
      cases.each do |(posts, ends_on), message|
        error = assert_raises(CreatorTimedLinks::Refused) { @links.create(posts: posts, title: "", ends_on: ends_on, max_days: 30, now: @noon) }
        assert_match(message, error.message)
      end
      assert_empty @http.calls
    end

    should "pass sampling's limit on to the creator in its words" do
      @http.answer({ error: "this creator already has 5 live links, the most allowed is 5: end one with End now, or wait for one to run out" }, status: 409)
      error = assert_raises(CreatorTimedLinks::Refused) { @links.create(posts: [picture], title: "", ends_on: Date.new(2026, 11, 20), max_days: 30, now: @noon) }
      assert_match(/already has 5 live links/, error.message)
    end
  end

  context "finish" do
    should "end the link by hash for this gallery" do
      @http.answer({ ok: true, ended: "d" * 32 })
      assert_equal "d" * 32, @links.finish("d" * 32)
      call = @http.calls.sole
      assert_equal [:delete, "#{BASE}/api/publish", { hash: "d" * 32, owner: @gallery.id.to_s }], [call[:method], call[:url], call[:options][:json]]
    end

    should "refuse a malformed hash without asking, and say a gone link is gone" do
      assert_raises(CreatorTimedLinks::Refused) { @links.finish("../x") }
      assert_empty @http.calls
      @http.answer({ error: "not one of this creator's live links" }, status: 404)
      error = assert_raises(CreatorTimedLinks::Refused) { @links.finish("e" * 32) }
      assert_match(/already ended/, error.message)
    end
  end
end
