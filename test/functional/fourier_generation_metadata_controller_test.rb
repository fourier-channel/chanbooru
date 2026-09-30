require "test_helper"

# The private store for AI generation data the tunnel strips on ingest
# (operator ruling 2026-09-28), driven the way the tunnel drives it: a JSON
# body with top-level keys (shared interface v2, 2026-09-29).
#
# Two properties matter most. The write never lets one poster's send replace
# another's record -- raw_md5 and poster are fixed by the first write. And the
# read answers the post's creator alone (FourierCreatorPrivacy), with everyone
# else getting the same 404 a missing record gets, byte for byte, so the
# answer never says whether there was something to refuse.
class FourierGenerationMetadataControllerTest < ActionDispatch::IntegrationTest
  CREATOR = "@alice:41chan.net"
  PARAMS_TEXT = "a cat, masterpiece\nNegative prompt: bad\nSteps: 20, Sampler: Euler a"

  # EVERY FIELD KEY fourier-tunnel CAN SEND -- the keys of strip-generation.js
  # `removed`, as its strip rules name them. THE SAME LIST is in
  # fourier-tunnel's strip-generation.test.js, and the two are kept equal by
  # hand: the tunnel's test goes red when the stripper emits a key its list
  # does not name, and this one goes red when FIELD_KEY refuses a key this
  # list names. So a drift is a red test on whichever side changes first, and
  # a key added on one side is added to BOTH files in the same change. Round
  # two let the tunnel send gif:Comment for a day while this endpoint refused
  # it, and each side's tests were green against its own stand-in (round-two
  # findings 12 and 14).
  TUNNEL_FIELD_KEYS = [
    # PNG text chunks, png:<keyword>: generators' own keywords
    "png:parameters", "png:postprocessing", "png:extras", "png:prompt", "png:workflow",
    "png:invokeai_metadata", "png:invokeai_graph", "png:invokeai_workflow", "png:sd-metadata", "png:Dream",
    "png:fooocus_scheme", "png:parameters-json", "png:smproj",
    # Easy Diffusion, one chunk per setting
    "png:negative_prompt", "png:use_stable_diffusion_model", "png:use_vae_model", "png:use_text_encoder_model",
    "png:use_lora_model", "png:lora_alpha", "png:use_hypernetwork_model", "png:hypernetwork_strength",
    "png:use_embedding_models", "png:use_embeddings_model", "png:use_controlnet_model", "png:control_filter_to_apply",
    "png:control_alpha", "png:use_face_correction", "png:use_upscale", "png:upscale_amount", "png:latent_upscaler_steps",
    "png:num_inference_steps", "png:guidance_scale", "png:distilled_guidance_scale", "png:prompt_strength",
    "png:sampler_name", "png:scheduler_name", "png:clip_skip", "png:seed", "png:width", "png:height", "png:tiling",
    # shared keywords, and NovelAI's
    "png:Comment", "png:Description", "png:Source", "png:Generation time",
    # XMP and raw profiles carried in PNG text chunks
    "png:XML:com.adobe.xmp", "png:Raw profile type exif", "png:Raw profile type APP1", "png:Raw profile type xmp",
    "png:Raw profile type iptc",
    # ImageMagick's EXIF mirrors, and the alpha-channel stealth payload
    "png:exif:UserComment", "png:exif:ImageDescription", "png:stealth",
    # EXIF (JPEG APP1, WebP EXIF, PNG eXIf)
    "exif:UserComment", "exif:ImageDescription", "exif:XPComment", "exif:Make", "exif:Model", "exif:DocumentName",
    # IPTC (JPEG APP13, PNG raw profile), by ExifTool's dataset name
    "iptc:Caption-Abstract", "iptc:ObjectName", "iptc:Keywords", "iptc:SpecialInstructions", "iptc:Writer-Editor",
    "iptc:Headline",
    # whole packets and comments
    "xmp", "webp:xmp", "jpeg:COM", "gif:Comment",
  ].freeze

  def body_for(md5, **overrides)
    {
      md5: md5,
      raw_md5: @raw_md5,
      source: "matrix",
      poster: CREATOR,
      fields: { "png:parameters" => PARAMS_TEXT, "png:workflow" => "{\"nodes\": []}" },
    }.merge(overrides)
  end

  def send_record(body, as_user: @bot)
    post_auth "/fourier/generation_metadata.json", as_user, as: :json, params: body
  end

  setup do
    @bot = create(:builder_user)
    @md5 = SecureRandom.hex(16)
    @raw_md5 = SecureRandom.hex(16)
  end

  context "POST /fourier/generation_metadata" do
    should "store the fields for a builder and never echo their text" do
      send_record(body_for(@md5))

      assert_response :success
      assert_equal({ "md5" => @md5, "stored" => 2 }, response.parsed_body)
      refute_includes response.body, "masterpiece"
      refute_includes response.body, "nodes"

      record = FourierGenerationMetadata.find_by!(md5: @md5)
      assert_equal "matrix", record.source
      assert_equal CREATOR, record.poster
      assert_equal @raw_md5, record.raw_md5
      assert_equal PARAMS_TEXT, record.fields["png:parameters"]
    end

    should "replace the fields on a re-send of the same original from the same poster" do
      send_record(body_for(@md5))
      send_record(body_for(@md5, poster: "@ALICE:41chan.net", fields: { "exif:UserComment" => "second read" }))

      assert_response :success
      assert_equal 1, response.parsed_body["stored"]
      record = FourierGenerationMetadata.find_by!(md5: @md5)
      assert_equal({ "exif:UserComment" => "second read" }, record.fields)
      assert_equal CREATOR, record.poster, "the poster is the first write's"
      assert_equal @raw_md5, record.raw_md5
    end

    # Two originals can strip to the same bytes (the same pixels saved with
    # different prompts). The record keeps the first one's text, and a send
    # naming another original replaces NOTHING -- from the same poster too.
    should "refuse a re-send naming a different original with 409 raw_md5_mismatch, and change nothing" do
      send_record(body_for(@md5))
      before = FourierGenerationMetadata.find_by!(md5: @md5).attributes

      [CREATOR, nil, "@mallory:41chan.net"].each do |poster|
        send_record(body_for(@md5, raw_md5: SecureRandom.hex(16), poster: poster, fields: { "png:parameters" => "junk" }))

        assert_response 409, poster.inspect
        assert_equal "raw_md5_mismatch", response.parsed_body["reason"], poster.inspect
        assert response.parsed_body["error"].present?
        assert response.parsed_body["fix"].present?
        refute_includes response.body, "junk"
      end
      assert_equal before, FourierGenerationMetadata.find_by!(md5: @md5).attributes
    end

    should "replace the fields on an admin's re-read (poster null), and keep the poster" do
      send_record(body_for(@md5))
      send_record(body_for(@md5, poster: nil, fields: { "exif:UserComment" => "rescanned" }))

      assert_response :success
      record = FourierGenerationMetadata.find_by!(md5: @md5)
      assert_equal({ "exif:UserComment" => "rescanned" }, record.fields)
      assert_equal CREATOR, record.poster, "a re-read never clears the poster"
    end

    should "refuse a re-send from a different poster with 409, error and fix, and change nothing" do
      send_record(body_for(@md5))
      before = FourierGenerationMetadata.find_by!(md5: @md5).attributes

      ["@mallory:41chan.net", "discord:1234"].each do |poster|
        send_record(body_for(@md5, poster: poster, fields: { "png:parameters" => "junk" }))

        assert_response 409, poster
        assert_equal "poster_mismatch", response.parsed_body["reason"], poster
        assert response.parsed_body["error"].present?
        assert response.parsed_body["fix"].present?
        refute_includes response.body, "junk"
      end
      assert_equal before, FourierGenerationMetadata.find_by!(md5: @md5).attributes
    end

    should "let nobody but a re-read replace a record first filed with no poster and no post" do
      send_record(body_for(@md5, poster: nil))
      assert_nil FourierGenerationMetadata.find_by!(md5: @md5).poster, "no post holds the md5, so there is no owner to adopt"

      send_record(body_for(@md5, poster: CREATOR, fields: { "png:parameters" => "claimed" }))

      assert_response 409
      assert_equal "poster_mismatch", response.parsed_body["reason"]
      record = FourierGenerationMetadata.find_by!(md5: @md5)
      assert_nil record.poster
      assert_equal PARAMS_TEXT, record.fields["png:parameters"]
    end

    # A !rescan carries no poster. The record's owner is then the recorded
    # creator of the post holding the md5 -- never a member's tag, never the
    # uploader -- and without one the record stays ownerless, served to
    # nobody (decision 2026-09-29, round-two findings 3 and 13).
    should "give a re-read's record the recorded creator of the post holding the md5 as its owner" do
      bot = create(:builder_user, name: "tunnel")
      post = create(:post, uploader: bot, md5: @md5)

      send_record(body_for(@md5, poster: nil))
      assert_response :success
      assert_nil FourierGenerationMetadata.find_by!(md5: @md5).poster, "no creator recorded yet: ownerless"

      FourierPostCreator.create!(post: post, mxid: CREATOR, recorded_by: bot.id)
      send_record(body_for(@md5, poster: nil, fields: { "png:parameters" => "re-read" }))
      assert_response :success
      record = FourierGenerationMetadata.find_by!(md5: @md5)
      assert_equal CREATOR, record.poster, "a re-read to an ownerless record adopts the creator now recorded"
      assert_equal({ "png:parameters" => "re-read" }, record.fields)

      # And a first write with no poster adopts at once.
      other_md5 = SecureRandom.hex(16)
      other = create(:post, uploader: bot, md5: other_md5)
      FourierPostCreator.create!(post: other, mxid: "@bob:41chan.net", recorded_by: bot.id)
      send_record(body_for(other_md5, raw_md5: SecureRandom.hex(16), poster: nil))
      assert_equal "@bob:41chan.net", FourierGenerationMetadata.find_by!(md5: other_md5).poster
    end

    should "never change an owner a re-read finds already set" do
      bot = create(:builder_user, name: "tunnel")
      post = create(:post, uploader: bot, md5: @md5)
      FourierPostCreator.create!(post: post, mxid: "@bob:41chan.net", recorded_by: bot.id)

      send_record(body_for(@md5))
      send_record(body_for(@md5, poster: nil, fields: { "png:parameters" => "re-read" }))

      assert_response :success
      assert_equal CREATOR, FourierGenerationMetadata.find_by!(md5: @md5).poster
    end

    should "refuse a second md5 for an original already filed, with 409 raw_md5_conflict and the way to find it" do
      send_record(body_for(@md5))
      other = SecureRandom.hex(16)
      send_record(body_for(other))

      assert_response 409
      assert_equal "raw_md5_conflict", response.parsed_body["reason"]
      assert_includes response.parsed_body["fix"], "/fourier/generation_metadata/raw/#{@raw_md5}.json"
      refute FourierGenerationMetadata.exists?(md5: other)
    end

    should "accept every field key the tunnel can send, one request with all of them" do
      fields = TUNNEL_FIELD_KEYS.index_with { |key| "text for #{key}" }
      send_record(body_for(@md5, source: "discord", poster: "discord:1234567890", fields: fields))

      assert_response :success, response.body
      assert_equal TUNNEL_FIELD_KEYS.size, response.parsed_body["stored"]
      assert_equal fields, FourierGenerationMetadata.find_by!(md5: @md5).fields
    end

    # The same list against the grammar, one key at a time, so a refusal
    # names the key.
    should "match every key the tunnel can send against FIELD_KEY, and refuse near misses" do
      TUNNEL_FIELD_KEYS.each { |key| assert_match FourierGenerationMetadata::FIELD_KEY, key }
      ["gif:comment", "gif:XMP", "iptc:", "iptc:2:120", "iptc:Caption Abstract", "exif:User-Comment", "jpeg:com", "png:"].each do |key|
        assert_no_match FourierGenerationMetadata::FIELD_KEY, key
      end
    end

    should "refuse a member with 403 and store nothing" do
      send_record(body_for(@md5), as_user: create(:user))

      assert_response 403
      refute FourierGenerationMetadata.exists?(md5: @md5)
    end

    should "refuse an anonymous caller with 403" do
      post "/fourier/generation_metadata.json", as: :json, params: body_for(@md5)

      assert_response 403
      refute FourierGenerationMetadata.exists?(md5: @md5)
    end

    should "answer a malformed md5 or raw_md5 with 422, error and fix" do
      [@md5.upcase, "abc", SecureRandom.hex(32), nil].each do |md5|
        send_record(body_for(md5))
        assert_response 422, "md5=#{md5.inspect}"
        assert response.parsed_body["error"].present?
        assert response.parsed_body["fix"].present?

        send_record(body_for(@md5, raw_md5: md5))
        assert_response 422, "raw_md5=#{md5.inspect}"
        assert response.parsed_body["fix"].present?
      end
      assert_equal 0, FourierGenerationMetadata.count
    end

    should "answer a bad source, poster or fields with 422, error and fix" do
      bad = [
        { source: "telegram" },
        { source: nil },
        { poster: "alice" },
        { poster: "discord:alice" },
        { poster: "@alice:41chan.net\u0000" },
        { poster: "@al\u0000ice:41chan.net" },
        { poster: "@alice:41chan\u0001.net" },
        { fields: {} },
        { fields: "png:parameters=x" },
        { fields: { "png:parameters" => { "nested" => "x" } } },
        { fields: { "png:parameters" => 7 } },
        { fields: { "gif:comment" => "x" } },
        { fields: { "png:" => "x" } },
        { fields: { "png:parameters" => "Steps: 20, Sampler: Euler a, CFG scale: 7, Seed: 1\u0000" } },
        { fields: { "png:parameters" => "ok", "jpeg:COM" => "a\u0000b" } },
      ]
      bad.each do |override|
        send_record(body_for(@md5, **override))

        assert_response 422, override.inspect
        assert response.parsed_body["error"].present?, override.inspect
        assert response.parsed_body["fix"].present?, override.inspect
      end
      refute FourierGenerationMetadata.exists?(md5: @md5)
    end

    should "answer fields over 4 MiB with 413, error and fix, and store nothing" do
      big = "x" * (FourierGenerationMetadata::MAX_FIELDS_BYTES + 1 - "png:workflow".bytesize)
      send_record(body_for(@md5, fields: { "png:workflow" => big }))

      assert_response 413
      assert response.parsed_body["error"].present?
      assert response.parsed_body["fix"].present?
      refute_includes response.body, "xxxxxxxx"
      refute FourierGenerationMetadata.exists?(md5: @md5)
    end

    should "accept fields of exactly 4 MiB" do
      exact = "x" * (FourierGenerationMetadata::MAX_FIELDS_BYTES - "png:workflow".bytesize)
      send_record(body_for(@md5, fields: { "png:workflow" => exact }))

      assert_response :success
    end
  end

  context "GET /fourier/generation_metadata/raw/:raw_md5" do
    setup do
      FourierGenerationMetadata.create!(md5: @md5, raw_md5: @raw_md5, source: "matrix", poster: CREATOR,
                                        fields: { "png:parameters" => "a secret prompt" })
    end

    should "answer a builder with the md5 the original was filed under, and no field text" do
      get_auth "/fourier/generation_metadata/raw/#{@raw_md5}.json", @bot

      assert_response :success
      assert_equal({ "md5" => @md5 }, response.parsed_body)
    end

    should "answer an unknown original with 404, and a malformed one with 422" do
      get_auth "/fourier/generation_metadata/raw/#{SecureRandom.hex(16)}.json", @bot
      assert_response 404
      assert response.parsed_body["fix"].present?

      get_auth "/fourier/generation_metadata/raw/#{@raw_md5.upcase}.json", @bot
      assert_response 422
    end

    should "refuse a member and an anonymous caller" do
      get_auth "/fourier/generation_metadata/raw/#{@raw_md5}.json", create(:user)
      assert_response 403
      refute_includes response.body, @md5

      reset!
      get "/fourier/generation_metadata/raw/#{@raw_md5}.json"
      assert_response 403
      refute_includes response.body, @md5
    end
  end

  # The browser read. Who it admits is FourierCreatorPrivacy's, proven door by
  # door in fourier_creator_only_data_test; this pins the route, the payload
  # and the one-404 property.
  context "GET /posts/:post_id/generation_data" do
    setup do
      @bot.update_columns(name: "tunnel") # a posting bot, by the real list
      @asset = create(:media_asset)
      @post = create(:post, uploader: @bot, md5: @asset.md5, media_asset: @asset)
      FourierPostCreator.create!(post: @post, mxid: CREATOR, recorded_by: @bot.id)
      @record = FourierGenerationMetadata.create!(md5: @post.md5, raw_md5: @raw_md5, source: "matrix", poster: CREATOR,
                                                  fields: { "png:parameters" => "a secret prompt" })
      bare_asset = create(:media_asset)
      @bare = create(:post, uploader: @bot, md5: bare_asset.md5, media_asset: bare_asset)
      FourierPostCreator.create!(post: @bare, mxid: CREATOR, recorded_by: @bot.id)
    end

    should "answer the creator with the record, and not name the poster" do
      get post_generation_data_path(@post), headers: { "X-Fourier-Identity" => CREATOR }

      assert_response :success
      body = response.parsed_body
      assert_equal @post.md5, body["md5"]
      assert_equal "matrix", body["source"]
      assert_equal({ "png:parameters" => "a secret prompt" }, body["fields"])
      assert body["created_at"].present?
      assert body["updated_at"].present?
      refute body.key?("poster")
      refute body.key?("raw_md5")
    end

    # A tunnel post made before stripping existed carries the unstripped
    # original, so its md5 is the record's raw_md5 (330 posts, 2026-09-30).
    should "answer the creator of a pre-strip post, whose md5 is the record's raw_md5" do
      old_asset = create(:media_asset)
      old_post = create(:post, uploader: @bot, md5: old_asset.md5, media_asset: old_asset)
      FourierPostCreator.create!(post: old_post, mxid: CREATOR, recorded_by: @bot.id)
      FourierGenerationMetadata.create!(md5: SecureRandom.hex(16), raw_md5: old_post.md5, source: "matrix", poster: CREATOR,
                                        fields: { "png:parameters" => "an older prompt" })

      get post_generation_data_path(old_post), headers: { "X-Fourier-Identity" => CREATOR }
      assert_response :success
      assert_equal({ "png:parameters" => "an older prompt" }, response.parsed_body["fields"])

      [create(:admin_user), create(:user)].each do |user|
        get_auth post_generation_data_path(old_post), user
        assert_response 404, user.level_string
        refute_includes response.body, "older prompt"
      end
    end

    should "serve the record filed under the post's own md5 before one whose raw_md5 matches it" do
      FourierGenerationMetadata.create!(md5: SecureRandom.hex(16), raw_md5: @post.md5, source: "matrix", poster: CREATOR,
                                        fields: { "png:parameters" => "the wrong record" })

      get post_generation_data_path(@post), headers: { "X-Fourier-Identity" => CREATOR }
      assert_response :success
      assert_equal({ "png:parameters" => "a secret prompt" }, response.parsed_body["fields"])
    end

    should "give an admin, a moderator, a member and the bot the not-found answer" do
      [create(:admin_user), create(:moderator_user), create(:user), @bot].each do |user|
        get_auth post_generation_data_path(@post), user
        assert_response 404, user.level_string
        refute_includes response.body, "secret"
      end
    end

    # The disclosure test. A refusal, a post with no record and a post that
    # does not exist must be the same response, down to the backtrace the
    # error page carries -- two raise sites would answer from two lines and
    # tell them apart. All three are asked from ONE line of this test: the
    # backtrace carries the caller's frames too.
    should "answer a refusal, a missing record and a missing post identically" do
      refused, missing, nonexistent = [@post.id, @bare.id, 0].map do |post_id|
        get "/posts/#{post_id}/generation_data.json"
        [response.status, response.body]
      end

      assert_equal 404, refused.first
      assert_equal refused, missing
      assert_equal refused, nonexistent
    end

    # The same property for a record this post's creator does not own: a
    # record filed by someone else under these bytes (an earlier post's, say)
    # is "no record", byte for byte, to the creator asking.
    should "answer a record the creator does not own exactly as a missing record, to the creator" do
      foreign_asset = create(:media_asset)
      foreign = create(:post, uploader: @bot, md5: foreign_asset.md5, media_asset: foreign_asset)
      FourierPostCreator.create!(post: foreign, mxid: CREATOR, recorded_by: @bot.id)
      FourierGenerationMetadata.create!(md5: foreign.md5, raw_md5: SecureRandom.hex(16), source: "matrix", poster: "@bob:41chan.net",
                                        fields: { "png:parameters" => "bob's secret prompt" })

      not_owned, missing, nonexistent = [foreign.id, @bare.id, 0].map do |post_id|
        get "/posts/#{post_id}/generation_data.json", headers: { "X-Fourier-Identity" => CREATOR }
        [response.status, response.body]
      end

      assert_equal 404, not_owned.first
      refute_includes not_owned.last, "bob"
      assert_equal not_owned, missing
      assert_equal not_owned, nonexistent
    end

    should "give the creator the not-found answer for a post with no record" do
      get post_generation_data_path(@bare), headers: { "X-Fourier-Identity" => CREATOR }

      assert_response 404
    end

    should "no longer answer the round-one read under /fourier/, which the proxy never routed here" do
      get_auth "/fourier/generation_metadata/#{@post.md5}.json", @bot

      assert_response 404
      refute_includes response.body, "secret"
    end
  end
end
