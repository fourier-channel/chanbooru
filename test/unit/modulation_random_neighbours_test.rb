# frozen_string_literal: true

require "test_helper"

# RANDOM MODE'S NEIGHBOURS, ROLLED BY THE MD5 SEEK.
#
# Every signed-in post page builds the random preset, whichever mode the viewer
# is in, and it rolled each neighbour with ORDER BY random() over the whole
# search. On production data (2026-09-26, 361,780 visible posts) that is a
# sequential scan evaluating the enforced blacklist -- sixteen
# `NOT string_to_array(tag_string, ' ') @> '{tag}'` clauses -- against every
# row: 44 seconds for one roll, EXPLAIN ANALYZE, and a fresh view rolls both
# sides. Anonymous viewers get no presets, which is why their post pages
# rendered in 50-150ms while a signed-in view sat for most of a minute.
#
# Danbooru's own Post.random (what /posts/random uses) picks a random md5 and
# seeks to the nearest matching post along the md5 index, so the filters run
# on a row or two: 7-17ms a roll on the same data, every pick matching the
# search. It is also rolled outside the query cache -- a web request caches
# identical SQL, and 20 cached picks came back as one post twenty times.
class ModulationRandomNeighboursTest < ActiveSupport::TestCase
  def component(post, viewer)
    ModulationPostComponent.new(post: post, viewer: viewer, query: "order:random")
  end

  def random_preset(post, viewer)
    component(post, viewer).nav_presets.find { |p| p[:key] == "random" }
  end

  # Every statement Active Record sends while the block runs.
  def statements
    sqls = []
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| sqls << payload[:sql] }
    yield
    sqls
  ensure
    ActiveSupport::Notifications.unsubscribe(sub)
  end

  context "Random mode on a post page" do
    setup do
      @viewer = create(:user)
      @posts = create_list(:post, 4)
    end

    should "roll by Danbooru's md5 seek, never by sorting the whole search at random" do
      sqls = as(@viewer) { statements { random_preset(@posts.first, @viewer) } }

      whole = sqls.select { |s| s.match?(/ORDER BY random\(\)/i) && s.exclude?("random_md5s") }
      assert_empty(whole, "a roll sorted the whole search by random(): #{whole.first.to_s.first(300)}")
      assert(sqls.any? { |s| s.include?("random_md5s") }, "no roll ran at all, so this proves nothing")
    end

    should "give two different neighbours, neither the post itself, inside a request's query cache" do
      preset = as(@viewer) { ActiveRecord::Base.cache { random_preset(@posts.first, @viewer) } }
      ids = [preset[:prev]&.fetch(:id), preset[:next]&.fetch(:id)]

      assert_equal(2, ids.compact.uniq.size, "neighbours #{ids.inspect}")
      assert_not_includes(ids, @posts.first.id)
      assert(ids.all? { |id| @posts.map(&:id).include?(id) })
    end

    should "give no neighbour when the post is the only one its search finds" do
      lone = create(:post, tag_string: "lonely_tag_only_here")
      preset = as(@viewer) do
        ModulationPostComponent.new(post: lone, viewer: @viewer, query: "lonely_tag_only_here order:random")
                               .nav_presets.find { |p| p[:key] == "random" }
      end

      assert_nil(preset[:prev])
      assert_nil(preset[:next])
    end
  end
end
