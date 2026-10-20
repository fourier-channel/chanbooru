require "test_helper"

# The provenance endpoint the posting bots call, driven the way they call it:
# a JSON body with top-level keys.
#
# The model keys (spectrum, hydra) are what light the lamp, and they reach
# record_partition! only if the controller lets them through. Until 2026-09-24
# it did not: wrap_parameters listed the bucket keys and not the model keys,
# so a JSON body's spectrum and hydra lists were never wrapped under
# fourier_tag_source and permit() saw nothing. Measured in production that
# day: 22.4M provenance rows, not one carrying either bit, four days after the
# lamp shipped. The model test passed the whole time because it calls
# record_partition! directly and never goes through this door.
class FourierTagSourcesControllerTest < ActionDispatch::IntegrationTest
  context "POST /posts/:post_id/tag_sources" do
    setup do
      @bot = create(:builder_user, name: "tunnel")
      @post = create(:post, tag_string: "a b m")
    end

    should "record which model reported each tag" do
      post_auth "/posts/#{@post.id}/tag_sources.json", @bot, as: :json,
        params: { auto: %w[a b], meta: %w[m], spectrum: %w[a m], hydra: %w[a b] }

      assert_response :success
      rows = FourierTagSource.where(post_id: @post.id).index_by(&:tag)
      assert_equal %w[a b m], rows.keys.sort
      assert rows["a"].spectrum? && rows["a"].hydra?, "a was reported by both models"
      assert rows["b"].hydra?, "b was reported by hydra"
      refute rows["b"].spectrum?, "b was not reported by spectrum"
      assert rows["m"].spectrum?, "m was reported by spectrum"
      refute rows["m"].hydra?, "m was not reported by hydra"
    end

    # An original character the hub would not declare is said in the answer,
    # with why and what to do, never dropped in silence (operator ruling
    # 2026-10-11: only the recorded creator's own name declares one).
    should "say which original characters it did not declare, and why" do
      post_auth "/posts/#{@post.id}/tag_sources.json", @bot, as: :json, params: { auto: %w[a], oc: %w[maple_(saber)] }

      assert_response :success
      assert_match(/has no recorded creator/, response.parsed_body.dig("original_characters_not_declared", "maple_(saber)"))
    end

    # THE WIRE CONTRACT with fourier-tunnel (2026-10-12): every qualified
    # prompt term that is not the poster's own arrives in BOTH the private
    # creator list and `oc`, and every legacy shape in `oc`. The booru
    # declares a legacy name (as itself, or as its alias's consequent) and an
    # established original character, keeps the rest as the private creator
    # rows they were sent as, and says nothing about them: not a refusal.
    should "declare a legacy name and keep someone else's qualified name private, with nothing reported" do
      FourierPostCreator.create!(post: @post, mxid: "@saber:41chan.net", recorded_by: @bot.id)
      sources = { auto: %w[a], creator: %w[saber_(fate)], oc: %w[oc_maple saber_(fate)] }
      post_auth "/posts/#{@post.id}/tag_sources.json", @bot, as: :json, params: sources

      assert_response :success
      assert_nil(response.parsed_body["original_characters_not_declared"])
      rows = FourierTagSource.where(post_id: @post.id).index_by(&:tag)
      assert(rows["oc_maple"].public?)
      assert_not(rows["saber_(fate)"].public?)
      assert_includes(@post.reload.tag_array, "oc_maple")
    end

    # A Discord post records no creator, and the tunnel offers every
    # qualified name on it: an offer is silent there too.
    should "say nothing about an offered name on a post with no recorded creator" do
      sources = { auto: %w[a], both: %w[a], creator: %w[saber_(fate)], oc: %w[oc_maple saber_(fate)] }
      post_auth "/posts/#{@post.id}/tag_sources.json", @bot, as: :json, params: sources

      assert_response :success
      assert_nil(response.parsed_body["original_characters_not_declared"])
      assert_not(FourierTagSource.find_by!(post_id: @post.id, tag: "saber_(fate)").public?)
      assert_includes(@post.reload.tag_array, "oc_maple")
    end
  end

  # THE READ IS A DOOR (review, 2026-09-24). Post#hidden_as_deleted? says a
  # deleted post answers nothing -- "not the page, not the tags, not the id"
  # -- and every other door asks it. This one did not: any caller, signed in
  # or not, read a jailed post's whole tag list here, the one list troll jail
  # exists to take out of view, and a signed-out caller read a gated post's.
  # Every reader (technetium's panel, sampling's lamp check, the tunnel's
  # duplicate projection) already treats a 404 as "no such post".
  context "GET /posts/:post_id/tag_sources" do
    setup do
      Danbooru.config.stubs(:deleted_post_visibility_level).returns(User::Levels::ADMIN)
      # an approver, as the sampling bot is: a member would hit the upload limit
      @uploader = create(:approver_user)
      @live = create(:post, tag_string: "a b", uploader: @uploader)
      @deleted = create(:post, tag_string: "a b", uploader: @uploader)
      @deleted.update_columns(is_deleted: true)
    end

    should "answer for a live post, signed in or not" do
      get "/posts/#{@live.id}/tag_sources.json"
      assert_response :success

      get_auth "/posts/#{@live.id}/tag_sources.json", create(:user)
      assert_response :success
    end

    should "answer nothing about a deleted post, by either scope, to anyone who may not see it" do
      [nil, create(:user), create(:builder_user)].each do |user|
        [{}, { scope: "public" }].each do |params|
          if user
            get_auth "/posts/#{@deleted.id}/tag_sources.json", user, params: params
          else
            get "/posts/#{@deleted.id}/tag_sources.json", params: params
          end
          assert_response 404, "#{user ? user.level_string : "anonymous"} #{params}"
        end
      end
    end

    should "still answer the uploader, as the post page does" do
      get_auth "/posts/#{@deleted.id}/tag_sources.json", @uploader
      assert_response :success

      get_auth "/posts/#{@deleted.id}/tag_sources.json", @uploader, params: { scope: "public" }
      assert_response :success
    end

    # Technetium's read (BUR review 2026-10-19). A both row is public and
    # reads as both to every viewer, its colouring saying the model agrees
    # with what the creator asked for (operator, 2026-10-19), and ?scope=public,
    # which a bot writes into Matrix room state, carries it as the both
    # source. Only creator-ONLY rows are private: the creator, by verified
    # identity, reads them; for everyone else a tag on the public list that
    # the prompt also holds is an ordinary unsourced tag (operator ruling
    # 2026-10-19), and one off the list is never named.
    should "answer every viewer a both row as both, and only the creator their private tags" do
      prompted = create(:post, tag_string: "a listed shared", uploader: @uploader)
      FourierTagSource.record_partition!(prompted, { creator: %w[listed shared unlisted_term], auto: %w[a shared] }, @uploader)
      FourierPostCreator.create!(post: prompted, mxid: "@alice:41chan.net", recorded_by: @uploader.id)

      [nil, create(:user), create(:moderator_user), create(:admin_user)].each do |user|
        label = user ? user.level_string : "anonymous"
        user ? get_auth("/posts/#{prompted.id}/tag_sources.json", user) : get("/posts/#{prompted.id}/tag_sources.json")
        assert_response :success
        body = response.parsed_body
        assert_equal ["shared"], body["both"], label
        assert_equal [], body["creator"], label
        assert_equal ["a"], body["auto"], label
        assert_equal ["listed"], body["unsourced"], label
        assert_equal %w[a listed shared], body["tag_string"].split.sort, label
        assert_not_includes response.body, "unlisted_term", label
      end

      get "/posts/#{prompted.id}/tag_sources.json", headers: { "X-Fourier-Identity" => "@alice:41chan.net" }
      body = response.parsed_body
      assert_equal ["shared"], body["both"]
      assert_equal %w[listed unlisted_term], body["creator"].sort
      assert_equal ["a"], body["auto"]

      get "/posts/#{prompted.id}/tag_sources.json", params: { scope: "public" }
      assert_equal %w[creator auto both meta], response.parsed_body["sources"].keys
      assert_equal ["shared"], response.parsed_body.dig("sources", "both")
      assert_equal ["a"], response.parsed_body.dig("sources", "auto")
      assert_equal %w[a shared], response.parsed_body["tags"].sort
    end

    should "answer nothing about a gated post to a signed-out caller" do
      gated = create(:post, tag_string: "a child", uploader: @uploader)
      assert gated.gated?, "fixture: the post is gated"

      get "/posts/#{gated.id}/tag_sources.json"
      assert_response 404
    end
  end

  # THE MODEL-BIT BACKFILL (2026-09-24). fourier-sampling's retag timer pushes
  # hydra's tags onto posts that already exist and recorded them with no model
  # bit at all, and 22.4M older rows predate the bits entirely -- the lamp
  # reads "no bit" as spectrum, so hydra's work was invisible and a tag both
  # models found never lit "both". This route is how the bits get there.
  #
  # The contract both repos implement: it ONLY ever ORs model bits in. It
  # never clears a bit, never moves a tag between buckets, never touches
  # public, status or added_by, and never fans out -- a lamp is not part of
  # the public projection.
  def models(user, entries, **opts)
    post_auth "/posts/tag_source_models.json", user, as: :json, params: { posts: entries }, **opts
  end

  def row(post, tag)
    FourierTagSource.find_by(post_id: post.id, tag: tag)
  end

  def everything_about(post)
    FourierTagSource.where(post_id: post.id).order(:tag).pluck(:tag, :source, :status, :public, :added_by, :created_at)
  end

  # Fork: the provenance routes are the posting bots' alone (BUR review
  # 2026-10-19, M3). Gated on is_builder? they let any builder, moderator or
  # admin ask record_models! whether a creator's private row exists (a tag
  # on the post answers "inserted" with no row and "skipped" with one), read
  # create's `recorded` count, mint creator rows, and delete them all with
  # replace_creator -- against the rule that a creator's private data is the
  # creator's, with no moderator or admin bypass (FourierCreatorPrivacy).
  context "an account that is not a posting bot" do
    setup do
      @post = create(:post, tag_string: "a b m secret")
      FourierTagSource.record_partition!(@post, { creator: %w[secret] }, create(:user))
    end

    should "refuse the model-bits and partition routes to a builder who is not a posting account" do
      [create(:builder_user), create(:moderator_user), create(:admin_user)].each do |user|
        before = everything_about(@post)

        post_auth "/posts/#{@post.id}/tag_sources.json", user, as: :json, params: { auto: %w[a], creator: %w[guess] }
        assert_response 403, "create, as #{user.level_string}"
        post_auth "/posts/#{@post.id}/tag_sources.json", user, as: :json, params: { replace_creator: true, creator: [] }
        assert_response 403, "replace_creator, as #{user.level_string}"
        models(user, [{ post_id: @post.id, spectrum: %w[secret], hydra: %w[secret] }])
        assert_response 403, "models, as #{user.level_string}"
        assert_not_includes(response.body, "skipped", "models, as #{user.level_string}")
        post_auth "/posts/#{@post.id}/tag_sources.json", user, as: :json, params: { mxc: "mxc://41chan.net/notabot" }
        assert_response 403, "mxc, as #{user.level_string}"

        assert_equal(before, everything_about(@post), "no row written or deleted, as #{user.level_string}")
        assert_not(PostMxc.exists?(mxc: "mxc://41chan.net/notabot"), "no mxc recorded, as #{user.level_string}")
      end
    end
  end

  context "POST /posts/tag_source_models" do
    setup do
      @bot = create(:builder_user, name: "sample")
      @post = create(:post, tag_string: "a b m")
      # Rows as the retag timer left them: model rows with no model bit.
      FourierTagSource.record_partition!(@post, { auto: %w[a b], meta: %w[m] }, @bot)
    end

    should "OR each model's bit into the rows that exist" do
      models(@bot, [{ post_id: @post.id, spectrum: %w[a m], hydra: %w[a b] }])

      assert_response :success
      assert_equal({ "updated" => 3, "inserted" => 0, "skipped" => 0, "missing_posts" => [] }, response.parsed_body)
      assert_equal :both, row(@post, "a").lamp
      assert_equal :hydra, row(@post, "b").lamp
      assert row(@post, "m").spectrum?
      assert_not row(@post, "m").hydra?
      # the bucket each row was in is the bucket it is still in
      assert_equal %i[auto auto meta], %w[a b m].map { |t| row(@post, t).bucket }
    end

    should "authenticate the way the bot does, with an API key over Basic auth" do
      key = create(:api_key, user: @bot)
      auth = "Basic #{::Base64.strict_encode64("#{@bot.name}:#{key.key}")}"

      post "/posts/tag_source_models.json",
           as: :json,
           headers: { HTTP_AUTHORIZATION: auth },
           params: { posts: [{ post_id: @post.id, hydra: %w[b] }] }

      assert_response :success
      assert row(@post, "b").hydra?
    end

    should "insert an approved public auto row for a tag on the post that has none" do
      @post.update!(tag_string: "a b m fresh")

      models(@bot, [{ post_id: @post.id, hydra: %w[fresh] }])

      assert_response :success
      assert_equal 1, response.parsed_body["inserted"]
      fresh = row(@post, "fresh")
      assert_equal FourierTagSource::AUTO | FourierTagSource::HYDRA, fresh.source
      assert_equal FourierTagSource::APPROVED, fresh.status
      assert_equal true, fresh.public
      assert_equal :auto, fresh.bucket
      assert_equal :hydra, fresh.lamp
    end

    should "skip a tag the post does not carry and has no row for" do
      models(@bot, [{ post_id: @post.id, hydra: %w[not_on_this_post] }])

      assert_response :success
      assert_equal({ "updated" => 0, "inserted" => 0, "skipped" => 1, "missing_posts" => [] }, response.parsed_body)
      assert_nil row(@post, "not_on_this_post")
    end

    should "never clear a bit" do
      models(@bot, [{ post_id: @post.id, spectrum: %w[a] }])
      models(@bot, [{ post_id: @post.id, hydra: %w[a] }])
      assert_equal :both, row(@post, "a").lamp

      # a later call naming only one model, or neither, takes nothing away
      models(@bot, [{ post_id: @post.id, spectrum: %w[a], hydra: [] }])
      models(@bot, [{ post_id: @post.id }])
      assert_equal :both, row(@post, "a").lamp
    end

    # Round-two finding 5: "updated" for a creator's private tag against
    # "skipped" for a wrong guess confirmed the guess. The answer depends on
    # the post's public list and public rows alone, never on a private row.
    # A private tag the post does not carry (the tunnel's shape) reads
    # exactly as a tag the post does not have: skipped, its row untouched. A
    # tag on the public list (the 2026-08-04..06 shape, or a person's add)
    # reads exactly as one with no row: inserted -- its private row becomes
    # the public both row, which everyone reads as both (operator, 2026-10-19:
    # a private row never subtracts from anyone's view, a model's lamp
    # included, and a both row is public in its own colouring). Asked of the
    # posting bot, the route's only caller since 2026-10-19 (no other account
    # reaches it: "an account that is not a posting bot", above).
    should "answer the posting bot by the public list alone, whatever a creator's private row holds" do
      creator = create(:user)
      FourierTagSource.record_partition!(@post, { creator: %w[secret] }, creator)
      legacy = create(:post, tag_string: "a legacy_secret")
      FourierTagSource.record_partition!(legacy, { creator: %w[legacy_secret] }, creator)
      control = create(:post, tag_string: "a legacy_secret")
      before = row(@post, "secret").attributes

      answers = [
        [@post, "secret"], [@post, "wrong_guess"], [legacy, "legacy_secret"], [control, "legacy_secret"], [legacy, "another_wrong_guess"],
      ].map do |post, guess|
        models(@bot, [{ post_id: post.id, spectrum: [guess], hydra: [guess] }])
        assert_response :success
        response.parsed_body
      end

      skipped = { "updated" => 0, "inserted" => 0, "skipped" => 1, "missing_posts" => [] }
      inserted = { "updated" => 0, "inserted" => 1, "skipped" => 0, "missing_posts" => [] }
      assert_equal [skipped, skipped, inserted, inserted, skipped], answers, "a right guess and a wrong one must read the same"
      assert_equal before, row(@post, "secret").attributes
      assert_equal [FourierTagSource::CREATOR | FourierTagSource::AUTO | FourierTagSource::SPECTRUM | FourierTagSource::HYDRA, true],
                   [row(legacy, "legacy_secret").source, row(legacy, "legacy_secret").public]
      assert_nil row(legacy, "another_wrong_guess")
    end

    should "report an unknown post and still do the rest" do
      missing = Post.maximum(:id).to_i + 1000

      models(@bot, [{ post_id: missing, hydra: %w[a] }, { post_id: @post.id, hydra: %w[a] }])

      assert_response :success
      assert_equal [missing], response.parsed_body["missing_posts"]
      assert_equal 1, response.parsed_body["updated"]
      assert row(@post, "a").hydra?
    end

    should "change nothing the second time it is sent" do
      @post.update!(tag_string: "a b m fresh")
      body = [{ post_id: @post.id, spectrum: %w[a m], hydra: %w[a b fresh nowhere] }]

      models(@bot, body)
      assert_equal({ "updated" => 3, "inserted" => 1, "skipped" => 1, "missing_posts" => [] }, response.parsed_body)
      first = everything_about(@post)

      models(@bot, body)
      assert_response :success
      assert_equal({ "updated" => 0, "inserted" => 0, "skipped" => 5, "missing_posts" => [] }, response.parsed_body)
      assert_equal first, everything_about(@post)
    end

    should "resolve names through the booru's aliases, as record_partition! does" do
      create(:tag_alias, antecedent_name: "old_name", consequent_name: "new_name")
      @post.update!(tag_string: "a b m new_name")

      models(@bot, [{ post_id: @post.id, hydra: %w[old_name] }])

      assert_response :success
      assert_nil row(@post, "old_name")
      assert row(@post, "new_name").hydra?
    end

    should "not fan out: a lamp is not part of the public projection" do
      FourierTagPropagation.expects(:fan_out!).never

      models(@bot, [{ post_id: @post.id, hydra: %w[a] }])

      assert_response :success
    end

    should "refuse an account that is not a posting bot" do
      models(create(:user), [{ post_id: @post.id, hydra: %w[a] }])

      assert_response 403
      assert_not row(@post, "a").hydra?
    end

    should "refuse an empty or oversized batch with 422, and say what to send" do
      models(@bot, [])
      assert_response 422
      assert_match(/1 to 100/, response.parsed_body["error"])

      models(@bot, Array.new(101) { { post_id: @post.id, hydra: %w[a] } })
      assert_response 422
      assert_not row(@post, "a").hydra?
    end

    should "refuse a post id that is not a number" do
      models(@bot, [{ post_id: "abc", hydra: %w[a] }])

      assert_response 422
      assert_match(/post_id/, response.parsed_body["error"])
    end
  end

  # FLAGGED-TAG QUARANTINE (operator rulings 2026-10-12): a posting bot keeps
  # reading and writing its own flagged post; another account's answers as a
  # missing one; the projection never carries the flagged name.
  context "a post carrying a flagged tag" do
    setup do
      @tunnel = create(:contributor_user, name: "tunnel")
      @sample = create(:approver_user, name: "sample")
      @post = as(@tunnel) { create(:post, uploader: @tunnel, md5: SecureRandom.hex(16), tag_string: "a secret_(thing)") }
      TagQuarantine.create!(tag: Tag.find_by_name("secret_(thing)"), state: "flagged", flagged_at: Time.zone.now)
    end

    should "answer its uploader, without the flagged name in the projection" do
      post_auth "/posts/#{@post.id}/tag_sources.json", @tunnel, as: :json, params: { auto: %w[a secret_(thing)] }
      assert_response :success
      assert_equal ["a"], response.parsed_body.dig("projection", "tags")

      get_auth "/posts/#{@post.id}/tag_sources.json", @tunnel, params: { scope: "public" }
      assert_response :success
      assert_equal ["a"], response.parsed_body["tags"]
    end

    should "answer another bot 404 for a read and a write, and count it missing for models" do
      post_auth "/posts/#{@post.id}/tag_sources.json", @sample, as: :json, params: { auto: %w[a] }
      assert_response 404
      get_auth "/posts/#{@post.id}/tag_sources.json", @sample, params: { scope: "public" }
      assert_response 404
      post_auth fourier_tag_source_models_path(format: :json), @sample, as: :json, params: { posts: [{ post_id: @post.id, hydra: %w[a] }] }
      assert_equal [@post.id], response.parsed_body["missing_posts"]
    end
  end

  # The tunnel's report of `params` for a post, as @bot.
  def report(params, post_id: @post.id)
    post_auth "/posts/#{post_id}/tag_sources.json", @bot, as: :json, params: params
    response.parsed_body
  end

  # GATE 3 FOR POSTS, piece B (fourier-basis docs/design/GATE3_MATRIX_POSTS.md):
  # the tunnel reports every other address of a post's image -- a re-upload of
  # the same bytes is a new mxc it maps to the post by md5 -- on this same
  # route, with "mxc". On its duplicate path the body carries ONLY the mxc.
  context "POST /posts/:post_id/tag_sources with an mxc" do
    setup do
      @bot = create(:builder_user, name: "tunnel")
      @post = create(:post, md5: SecureRandom.hex(16), tag_string: "a b", source: "mxc://41chan.net/original")
    end

    should "record an mxc-only body as an alias, changing no tag" do
      tags = @post.reload.tag_string
      assert_no_difference(-> { FourierTagSource.count }) do
        body = report({ mxc: "mxc://41chan.net/dup1" })
        assert_response :success
        assert_equal({ "post_id" => @post.id, "mxc" => { "accepted" => true }}, body)
      end
      assert_equal [@post.id, "alias"], PostMxc.where(mxc: "mxc://41chan.net/dup1").pick(:post_id, :source)
      assert_equal tags, @post.reload.tag_string
    end

    should "record it beside a tag partition, answering both" do
      body = report({ auto: %w[a b], mxc: "mxc://41chan.net/dup2" })
      assert_response :success
      assert_equal({ "accepted" => true }, body["mxc"])
      assert_equal 2, body["recorded"]
      assert PostMxc.exists?(post_id: @post.id, mxc: "mxc://41chan.net/dup2")
    end

    should "be idempotent" do
      2.times do
        assert_equal({ "accepted" => true }, report({ mxc: "mxc://41chan.net/dup3" })["mxc"])
      end
      assert_equal 1, PostMxc.where(mxc: "mxc://41chan.net/dup3").count
    end

    should "accept the post's own source" do
      assert_equal({ "accepted" => true }, report({ mxc: "mxc://41chan.net/original" })["mxc"])
      assert_equal "post_source", PostMxc.find_by!(mxc: "mxc://41chan.net/original").source
    end

    should "answer no_such_post in the body for a post that does not exist" do
      body = report({ mxc: "mxc://41chan.net/dup4" }, post_id: 0)
      assert_response :success
      assert_equal({ "accepted" => false, "reason" => "no_such_post" }, body["mxc"])
      assert_not PostMxc.exists?(mxc: "mxc://41chan.net/dup4")
    end

    should "keep the 404 for a tag partition on a missing post, saying what became of the mxc" do
      body = report({ auto: %w[a], mxc: "mxc://41chan.net/dup5" }, post_id: 0)
      assert_response 404
      assert_equal({ "accepted" => false, "reason" => "no_such_post" }, body["mxc"])
    end

    should "answer mxc_mapped_elsewhere for an mxc another post holds" do
      other = create(:post, md5: SecureRandom.hex(16), source: "mxc://41chan.net/theirs")
      body = report({ mxc: "mxc://41chan.net/theirs" })
      assert_response :success
      assert_equal({ "accepted" => false, "reason" => "mxc_mapped_elsewhere" }, body["mxc"])
      assert_equal other.id, PostMxc.find_by!(mxc: "mxc://41chan.net/theirs").post_id
    end

    should "recompute the post's rooms from its new address" do
      room = MatrixRoom.create!(room_id: "!dup:41chan.net")
      MatrixMedia.create!(mxc: "mxc://41chan.net/dup6", room_ids: [room.id], snapshot_head: 1, snapshot_at: Time.zone.now)
      assert_equal [], @post.reload.room_ids
      report({ mxc: "mxc://41chan.net/dup6" })
      assert_equal [room.id], @post.reload.room_ids
    end

    should "refuse an mxc that is not one, naming the shape" do
      report({ mxc: "https://example.com/x.png" })
      assert_response 422
      assert_match(%r{mxc://<server>/<media id>}, response.parsed_body["error"])
    end

    should "refuse a caller that is not a posting bot" do
      post_auth "/posts/#{@post.id}/tag_sources.json", create(:user), as: :json, params: { mxc: "mxc://41chan.net/dup7" }
      assert_response 403
      assert_not PostMxc.exists?(mxc: "mxc://41chan.net/dup7")
    end

    should "answer exactly as before when no mxc is sent" do
      body = report({ auto: %w[a b] })
      assert_response :success
      assert_equal %w[post_id projection recorded], body.keys.sort
      report({}, post_id: 0)
      assert_response 404
    end
  end
end
