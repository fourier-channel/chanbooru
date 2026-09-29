require "test_helper"

# Where AI generation data may be SEEN: by the post's creator, and by nobody
# else -- not an admin (operator rulings 2026-09-28 and 2026-09-29). Who the
# creator is, door by door and viewer by viewer, is
# fourier_creator_only_data_test; this file pins WHAT is withheld.
#
# Two halves. The media_metadata half closes a leak that predates the ruling:
# ExifTool's output for every original is stored whole, and until
# FourierGenerationFilter the media asset page, /media_metadata.json, every
# only=media_metadata include and the exif: search handed a prompt to anyone
# who asked. The post-page half is the FourierGenerationMetadata record.
#
# Each door is asked twice, once as someone who must be refused and once as
# the creator, who must get through: a filter that hid everything from
# everyone would pass every refusal on its own. Searches are the exception --
# refused for EVERYONE, creator included, because one search spans every
# creator's images.
class FourierGenerationDataVisibilityTest < ActionDispatch::IntegrationTest
  CREATOR = "@alice:41chan.net"
  AS_CREATOR = { "X-Fourier-Identity" => CREATOR }.freeze
  PROMPT = "secret cat prompt\nNegative prompt: bad\nSteps: 20, Sampler: Euler a"

  # A PNG's ExifTool output as the booru stores it: generation keys beside
  # ordinary ones. The IFD0:Make value is ComfyUI's WebP habit -- a workflow in
  # a camera field -- and is caught by value, not by name; the Easy Diffusion
  # setting chunks are caught by name.
  GENERATION_METADATA = {
    "File:FileType" => "PNG",
    "PNG:ColorType" => "RGB",
    "PNG:ImageWidth" => 1,
    "PNG:ImageHeight" => 1,
    "PNG:Parameters" => PROMPT,
    "PNG:Workflow" => "{\"secret\": \"workflow\"}",
    "PNG:Use_stable_diffusion_model" => "secret_checkpoint_v2",
    "PNG:Guidance_scale" => "7.5",
    "ExifIFD:UserComment" => "secret user comment",
    "IFD0:Make" => "workflow:{\"secret\": 1}",
    "IFD0:Model" => "prompt:{\"secret\": 2}",
    "IFD0:Orientation" => "Horizontal (normal)",
    "ICC_Profile:ProfileDescription" => "sRGB IEC61966-2.1",
  }.freeze

  HIDDEN_KEYS = %w[PNG:Parameters PNG:Workflow PNG:Use_stable_diffusion_model PNG:Guidance_scale ExifIFD:UserComment IFD0:Make IFD0:Model].freeze
  KEPT_KEYS = %w[File:FileType PNG:ColorType PNG:ImageWidth IFD0:Orientation ICC_Profile:ProfileDescription].freeze

  # The Modulation page's embedded payload -- what its client renders from.
  def modulation_payload
    JSON.parse(css_select(".modulation").first["data-payload"])
  end

  # A search refused for every viewer: a member, an admin, and the creator of
  # this very image -- a search is not scoped to one creator's images.
  def refused_for_everyone(path_for)
    [[@member, {}], [@admin, {}], [nil, AS_CREATOR]].each do |user, headers|
      reset!
      user ? get_auth(path_for.call, user, headers: headers) : get(path_for.call, headers: headers)
      assert_response :success
      assert_equal [], response.parsed_body, "#{user&.level_string || "creator"} searched #{path_for.call}"
    end
  end

  setup do
    @member = create(:user)
    @admin = create(:admin_user)
    @meta = create(:media_metadata, metadata: GENERATION_METADATA)
    @asset = @meta.media_asset
    @post = create(:post, md5: @asset.md5, media_asset: @asset, file_ext: "png")
    FourierPostCreator.create!(post: @post, mxid: CREATOR, recorded_by: @post.uploader_id)
  end

  context "media metadata" do
    should "keep reading the whole row inside the app" do
      assert @asset.reload.is_ai_generated?, "is_ai_generated? reads the stored metadata, not the filtered view"
      assert_equal PROMPT, @asset.metadata["PNG:Parameters"]
    end

    should "hide generation keys on the media asset page from a member and an admin, and show them to the creator" do
      [@member, @admin].each do |user|
        get_auth media_asset_path(@asset), user
        assert_response :success
        refute_includes response.body, "secret", user.level_string
        assert_includes response.body, "sRGB IEC61966-2.1"
        assert_includes response.body, "Horizontal (normal)"
      end

      reset!
      get media_asset_path(@asset), headers: AS_CREATOR
      assert_response :success
      assert_includes response.body, "secret cat prompt"
      assert_includes response.body, "secret user comment"
      assert_includes response.body, "secret_checkpoint_v2"
    end

    should "hide generation keys from an anonymous viewer of the media asset page" do
      get media_asset_path(@asset)
      assert_response :success
      refute_includes response.body, "secret"
    end

    should "count only visible keys in the media asset table" do
      get_auth media_assets_path(mode: "table", search: { id: @asset.id }), @admin
      assert_response :success
      assert_select "a[href='#{media_asset_path(@asset)}']", text: "#{GENERATION_METADATA.size - HIDDEN_KEYS.size} tags"

      reset!
      get media_assets_path(mode: "table", search: { id: @asset.id }), headers: AS_CREATOR
      assert_select "a[href='#{media_asset_path(@asset)}']", text: "#{GENERATION_METADATA.size} tags"
    end

    should "hide generation keys in /media_metadata.json from an admin and show them to the creator" do
      get_auth media_metadata_path(search: { id: @meta.id }), @admin, as: :json
      assert_response :success
      metadata = response.parsed_body.sole["metadata"]
      HIDDEN_KEYS.each { |key| refute metadata.key?(key), "#{key} leaked" }
      KEPT_KEYS.each { |key| assert metadata.key?(key), "#{key} was hidden" }

      reset!
      get media_metadata_path(search: { id: @meta.id }), headers: AS_CREATOR, as: :json
      metadata = response.parsed_body.sole["metadata"]
      assert_equal PROMPT, metadata["PNG:Parameters"]
      HIDDEN_KEYS.each { |key| assert metadata.key?(key), "#{key} was hidden from the creator" }
    end

    should "hide generation keys in /media_metadata.xml from an admin" do
      get_auth media_metadata_path(format: :xml, search: { id: @meta.id }), @admin
      assert_response :success
      refute_includes response.body, "secret"
      assert_includes response.body, "sRGB IEC61966-2.1"

      reset!
      get media_metadata_path(format: :xml, search: { id: @meta.id }), headers: AS_CREATOR
      assert_includes response.body, "secret cat prompt"
    end

    should "hide generation keys in only=media_metadata includes from an admin" do
      get_auth media_asset_path(@asset, format: :json, only: "id,media_metadata"), @admin
      assert_response :success
      refute_includes response.body, "secret"
      assert_equal "RGB", response.parsed_body.dig("media_metadata", "metadata", "PNG:ColorType")

      get_auth post_path(@post, format: :json, only: "id,media_metadata"), @admin
      assert_response :success
      refute_includes response.body, "secret"

      reset!
      get post_path(@post, format: :json, only: "id,media_metadata"), headers: AS_CREATOR
      assert_equal PROMPT, response.parsed_body.dig("media_metadata", "metadata", "PNG:Parameters")
    end

    should "hide generation keys from a moderator, who is not a reader" do
      get_auth media_metadata_path(search: { id: @meta.id }), create(:moderator_user), as: :json
      refute response.parsed_body.sole["metadata"].key?("PNG:Parameters")
    end

    context "searched" do
      should "find nothing on a generation key, for anyone" do
        [
          { metadata_has_key: "PNG:Parameters" },
          { metadata_has_key: ["PNG:Parameters"] },
          { metadata_has_key: ["PNG:ColorType", "PNG:Use_stable_diffusion_model"] },
          { metadata: { "PNG:Parameters" => PROMPT } },
          { metadata: { "PNG:Guidance_scale" => "7.5" } },
          { metadata: { "ExifIFD:UserComment" => "secret user comment" } },
          { metadata: { "IFD0:Make" => "workflow:{\"secret\": 1}" } },
        ].each do |search|
          refused_for_everyone(-> { media_metadata_path(format: :json, search: search) })
        end
      end

      # Finding 16 (round one): the array form bound straight back into the
      # jsonb `?` query past a guard that only looked at a string. Asserted
      # against the row it would have listed, as the anonymous caller the
      # policy lets in.
      should "not list the row for an array-form metadata_has_key" do
        get media_metadata_path(search: { metadata_has_key: ["PNG:Parameters"] }), as: :json
        assert_response :success
        assert_equal [], response.parsed_body

        get media_metadata_path(search: { metadata_has_key: "PNG:ColorType" }), as: :json
        assert_includes response.parsed_body.pluck("id"), @meta.id, "the ordinary has-key search stopped working"
      end

      should "still find an ordinary key for a member" do
        get_auth media_metadata_path(search: { metadata: { "PNG:ColorType" => "RGB" } }), @member, as: :json
        assert_equal [@meta.id], response.parsed_body.pluck("id")
      end

      should "find nothing through /media_assets search[metadata], for anyone" do
        refused_for_everyone(-> { media_assets_path(format: :json, search: { metadata: { "PNG:Parameters" => PROMPT } }) })
      end

      should "find nothing through the exif: metatag on posts, for anyone" do
        refused_for_everyone(-> { posts_path(tags: "exif:PNG:Parameters", format: :json) })

        get_auth posts_path(tags: "exif:PNG:ColorType=RGB", format: :json), @member
        assert_equal [@post.id], response.parsed_body.pluck("id")
      end

      should "not fail on a negated generation exif: term" do
        get_auth posts_path(tags: "-exif:PNG:Parameters", format: :json), @member
        assert_response :success
      end

      should "find nothing through the exif: metatag on media assets, for anyone" do
        refused_for_everyone(-> { media_assets_path(format: :json, search: { ai_tags_match: "exif:PNG:Parameters" }) })
      end
    end
  end

  context "the post page" do
    setup do
      @record = FourierGenerationMetadata.create!(md5: @post.md5, raw_md5: SecureRandom.hex(16), source: "matrix", poster: CREATOR,
                                                  fields: { "png:parameters" => "a <b>bold</b> secret prompt", "png:workflow" => "{\"nodes\": []}" })
    end

    should "hand the generation data to the creator by their verified identity" do
      get post_path(@post, preset: "modulation"), headers: AS_CREATOR
      assert_response :success
      assert_select "[data-region=generation]", 1
      generation = modulation_payload["generation"]
      assert_equal "matrix", generation["source"]
      assert_equal [["png:parameters", "a <b>bold</b> secret prompt"], ["png:workflow", "{\"nodes\": []}"]], generation["fields"]
    end

    should "withhold it from an admin, a moderator, a member, another MXID and an anonymous viewer" do
      [@admin, create(:moderator_user), @member].each do |user|
        get_auth post_path(@post, preset: "modulation"), user
        assert_response :success
        assert_nil modulation_payload["generation"], user.level_string
        refute_includes response.body, "secret prompt"
      end

      reset!
      get post_path(@post, preset: "modulation"), headers: { "X-Fourier-Identity" => "@mallory:41chan.net" }
      assert_nil modulation_payload["generation"]
      refute_includes response.body, "secret prompt"

      reset!
      get post_path(@post, preset: "modulation")
      assert_nil modulation_payload["generation"]
    end

    should "hand nothing when the post has no record, even to the creator" do
      @record.destroy!
      get post_path(@post, preset: "modulation"), headers: AS_CREATOR
      assert_nil modulation_payload["generation"]
    end

    # The client-side navigation door: the neighbour's payload is fetched from
    # here, so it must apply the same gate with the same identity.
    should "gate the navigation payload the same way" do
      get post_modulation_path(@post), headers: AS_CREATOR, as: :json
      assert_response :success
      assert_equal 2, response.parsed_body.dig("generation", "fields").size

      get post_modulation_path(@post), headers: { "X-Fourier-Identity" => "@mallory:41chan.net" }, as: :json
      assert_response :success
      assert_nil response.parsed_body["generation"]
      refute_includes response.body, "secret prompt"
    end

    should "render the section on the historical page for the creator, escaped, and not for an admin" do
      get post_path(@post, preset: "historical"), headers: AS_CREATOR
      assert_response :success
      assert_select "#post-generation-data pre", 2
      assert_select "#post-generation-data pre", text: "a <b>bold</b> secret prompt"
      assert_select "#post-generation-data pre b", 0

      get_auth post_path(@post, preset: "historical"), @admin
      assert_response :success
      assert_select "#post-generation-data", 0
      refute_includes response.body, "secret prompt"
    end
  end
end
