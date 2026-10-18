# frozen_string_literal: true

require "test_helper"

# THE PREFETCH FLAVOUR of /posts/:id/modulation.json (?prefetch=1). The post
# view fetches its neighbours' payloads ahead of the viewer so a step lands at
# once. Those builds are not visits, and the full build treated them as one:
#
# - random's trail took every prefetched post as a fresh arrival (pushed it)
#   and could roll its frontier, so the trail filled with posts the viewer
#   never stood on, and walking back retraced steps nobody took;
# - each rendered the comment section, below the fold, for a post that might
#   never be shown.
#
# So a prefetch never pushes: a post random's trail does not hold gets random
# `deferred` (empty, no roll). A post the trail holds is answered from it, and
# at an end its frontier is rolled -- the next random post in the direction the
# viewer is walking, which a random walk needs before it gets there or every
# step waits on a second build (review, 2026-10-18).
#
# THE VISIT READ (?visit=1). The page commits a prefetched payload and then
# records the visit with a read that carries ONLY what the prefetch lacked:
# random's preset (pushing the post and rolling its frontier) with that
# preset's candidates, and the comment section. Not the full payload again --
# that doubled the builds per step, and every keyset mode's searches with it.
class ModulationPrefetchTest < ActionDispatch::IntegrationTest
  setup do
    @viewer = create(:user)
    @uploader = create(:user)
    @posts = as(@uploader) { (0...8).map { create(:post, uploader: @uploader, tag_string: "pfq") } }
    @trail = @posts.first(5).map(&:id)
    ModulationSetting.create!(user: @viewer, random_trails: { "pfq" => { "ids" => @trail, "t" => 1 }})
  end

  def fetch(post, **params)
    get_auth post_modulation_path(post, format: :json, q: "pfq", **params), @viewer
    assert_response :success
    response.parsed_body
  end

  def random(body)
    body.fetch("presets").find { it["key"] == "random" }
  end

  def stored
    ModulationSetting.find_by!(user_id: @viewer.id).random_trails
  end

  context "a prefetch" do
    should "leave the trail as it was for a post not on it, and defer random" do
      before = stored
      body = fetch(@posts.last, prefetch: 1)

      assert_equal before, stored, "the trail row is untouched"
      r = random(body)
      assert_equal true, r["deferred"]
      assert_equal [], r["prev_candidates"]
      assert_equal [], r["next_candidates"]
      search = body.fetch("presets").find { it["key"] == "search" }
      assert_not search.key?("deferred"), "only random defers"
      assert_not_empty search["next_candidates"] + search["prev_candidates"], "the keyset modes are built as ever"
    end

    should "answer random from the trail for a post in the middle of it, writing nothing" do
      before = stored
      body = fetch(Post.find(@trail[2]), prefetch: 1)

      assert_equal before, stored
      r = random(body)
      assert_not r.key?("deferred")
      assert_equal [@trail[1], @trail[0]], r["prev_candidates"].pluck("id")
      assert_equal [@trail[3], @trail[4]], r["next_candidates"].pluck("id")
    end

    should "roll the frontier for a post at the trail's end, pushing nothing" do
      body = fetch(Post.find(@trail.last), prefetch: 1)

      ids = stored.dig("pfq", "ids")
      assert_equal @trail, ids.first(@trail.size), "nothing pushed, nothing reordered"
      assert_equal @trail.size + 1, ids.size, "one fresh post rolled onto the far end"
      r = random(body)
      assert_not r.key?("deferred")
      assert_equal [ids.last], r["next_candidates"].pluck("id")
      assert_equal @trail.reverse.drop(1).first(PostNeighbors::DEPTH), r["prev_candidates"].pluck("id")
    end

    should "carry no comment section" do
      body = fetch(@posts.last, prefetch: 1)
      assert_not body.key?("comments_html")
    end

    should "give the deferred random preset the documented keys and one more" do
      body = fetch(@posts.last, prefetch: 1)
      assert_equal %w[deferred history key label next_candidates next_more prev_candidates prev_more search], random(body).keys.sort
    end
  end

  context "a visit read" do
    should "record the visit on the trail and carry random's preset, its candidates and the comments, nothing else" do
      body = fetch(@posts.last, visit: 1)

      ids = stored.dig("pfq", "ids")
      assert_includes ids, @posts.last.id, "a fresh arrival is pushed"
      assert_equal %w[candidates comments_html id presets], body.keys.sort
      assert_equal @posts.last.id, body["id"]
      assert_equal ["random"], body["presets"].pluck("key")
      r = random(body)
      assert_not r.key?("deferred")
      assert_equal @trail.reverse.first(PostNeighbors::DEPTH), r["prev_candidates"].pluck("id"), "back is where random was"
      assert_equal 1, r["next_candidates"].size, "forward is one fresh roll"
      assert_equal (r["prev_candidates"] + r["next_candidates"]).pluck("id").map(&:to_s).sort, body["candidates"].keys.sort
      assert_kind_of String, body["comments_html"]
    end

    should "run none of the keyset modes' searches" do
      PostNeighbors.expects(:new).never
      fetch(@posts.last, visit: 1)
    end
  end

  context "a full read" do
    should "record the visit on the trail and carry the comment section, as before" do
      body = fetch(@posts.last)

      assert_includes stored.dig("pfq", "ids"), @posts.last.id, "a fresh arrival is pushed"
      assert_not random(body).key?("deferred")
      assert_kind_of String, body["comments_html"]
    end
  end
end
