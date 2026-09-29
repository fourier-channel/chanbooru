require "test_helper"

# CREATOR DECIDES WHO CAN SEE WHAT, ALWAYS (operator ruling 2026-09-29).
#
# One rule -- FourierCreatorPrivacy -- for a post's private creator tags and
# its generation data, and this file asks it at EVERY door either one leaves
# by, as every kind of viewer:
#
#   page_tags        the Modulation post page's tag buckets
#   page_blacklist   the page's blacklist data-tags
#   page_generation  the page's "Generation data" section payload
#   nav_tags         the client-side navigation payload's tag buckets
#   nav_generation   the navigation payload's generation data
#   tag_sources      /posts/:id/tag_sources.json (Technetium's read)
#   generation_json  /posts/:id/generation_data.json
#   historical       the historical post page's generation section
#   asset_page       the media asset page's ExifTool metadata
#   metadata_json    /media_metadata.json
#
# Every door, for every viewer, compared as ONE hash, so a failure names the
# door that disagreed. A filter that hid everything from everyone would pass
# every refusal here, which is why the readers are asked the same questions.
#
# The posts are the tunnel's shape: the private creator tag is its sidecar row
# and is NOT in tag_string (fourier-tunnel 37270f5). Round two's fixture put
# it in tag_string too, and every creator assertion passed while no real
# creator saw their own tag (round-two finding 1). The posting bot is the
# production account name, `tunnel`, asked through the real list.
class FourierCreatorOnlyDataTest < ActionDispatch::IntegrationTest
  CREATOR = "@alice:41chan.net"
  SECRET_TAG = "secret_prompt_tag"
  PROMPT = "a secret cat prompt"
  EXIF_PROMPT = "exif secret prompt\nNegative prompt: bad\nSteps: 20, Sampler: Euler a"

  DOORS = %i[page_tags page_blacklist page_generation nav_tags nav_generation tag_sources
             generation_json historical asset_page metadata_json].freeze
  SEES_ALL = DOORS.index_with(true).freeze
  SEES_NONE = DOORS.index_with(false).freeze
  # The doors the generation RECORD leaves by. The ExifTool metadata doors
  # (asset_page, metadata_json) read the image's own file, not the record.
  RECORD_DOORS = %i[page_generation nav_generation generation_json historical].freeze

  # A post as the tunnel makes one: the stripped image, its ExifTool row
  # (still carrying a prompt, as rows written before stripping do), the
  # prompt's private creator tag -- a sidecar row, NOT in tag_string -- and
  # the filed generation record, owned by `poster`.
  def make_post(uploader:, tags: "landscape", poster: CREATOR, meta: nil)
    meta ||= create(:media_metadata, metadata: { "File:FileType" => "PNG", "PNG:ColorType" => "RGB", "PNG:Parameters" => EXIF_PROMPT })
    post = create(:post, uploader: uploader, md5: meta.media_asset.md5, media_asset: meta.media_asset, file_ext: "png",
                         rating: "s", tag_string: tags)
    FourierTagSource.record_partition!(post, { creator: [SECRET_TAG], auto: tags.split }, uploader)
    assert_not_includes post.reload.tag_array, SECRET_TAG, "the fixture must be the tunnel's shape"
    if poster
      FourierGenerationMetadata.create!(md5: post.md5, raw_md5: SecureRandom.hex(16), source: "matrix", poster: poster,
                                        fields: { "png:parameters" => PROMPT })
    end
    post
  end

  # What `user` (signed in, or nil) carrying the verified Matrix identity
  # `mxid` (or none) sees of `post`'s creator-only data, door by door.
  def ask(post, user: nil, mxid: nil)
    reset!
    login_as(user) if user
    headers = mxid ? { "X-Fourier-Identity" => mxid } : {}
    seen = {}

    get post_path(post, preset: "modulation"), headers: headers
    assert_response :success
    payload = JSON.parse(css_select(".modulation").first["data-payload"])
    seen[:page_tags] = payload["tags"].values.flatten.include?(SECRET_TAG)
    seen[:page_blacklist] = payload.dig("blacklist", "data-tags").to_s.split.include?(SECRET_TAG)
    seen[:page_generation] = payload.dig("generation", "fields").to_a.flatten.include?(PROMPT)

    get post_modulation_path(post), headers: headers, as: :json
    assert_response :success
    seen[:nav_tags] = response.parsed_body["tags"].values.flatten.include?(SECRET_TAG)
    seen[:nav_generation] = response.body.include?(PROMPT)

    get "/posts/#{post.id}/tag_sources.json", headers: headers
    assert_response :success
    seen[:tag_sources] = response.body.include?(SECRET_TAG)

    get post_generation_data_path(post), headers: headers
    seen[:generation_json] = response.status == 200 && response.parsed_body.dig("fields", "png:parameters") == PROMPT
    assert_includes [200, 404], response.status

    get post_path(post, preset: "historical"), headers: headers
    assert_response :success
    seen[:historical] = css_select("#post-generation-data pre").map(&:text).include?(PROMPT)

    get media_asset_path(post.media_asset), headers: headers
    assert_response :success
    seen[:asset_page] = response.body.include?("exif secret prompt")

    get media_metadata_path(search: { id: post.media_asset.media_metadata.id }), headers: headers, as: :json
    seen[:metadata_json] = response.parsed_body.sole["metadata"]["PNG:Parameters"] == EXIF_PROMPT

    seen
  end

  setup do
    @bot = create(:builder_user, name: "tunnel")
    @post = make_post(uploader: @bot, tags: "41chan_alice landscape")
    FourierPostCreator.create!(post: @post, mxid: CREATOR, recorded_by: @bot.id)
    @member = create(:user)
  end

  context "a tunnel post with a recorded creator" do
    should "show everything to the creator by verified identity, signed out or signed in" do
      assert_equal SEES_ALL, ask(@post, mxid: CREATOR)
      assert_equal SEES_ALL, ask(@post, user: @member, mxid: CREATOR)
      assert_equal SEES_ALL, ask(@post, mxid: "@ALICE:41chan.net")
    end

    should "show nothing to an admin" do
      assert_equal SEES_NONE, ask(@post, user: create(:admin_user))
    end

    should "show nothing to a moderator" do
      assert_equal SEES_NONE, ask(@post, user: create(:moderator_user))
    end

    should "show nothing to another member, with or without an identity of their own" do
      assert_equal SEES_NONE, ask(@post, user: @member)
      assert_equal SEES_NONE, ask(@post, user: @member, mxid: "@mallory:41chan.net")
    end

    should "show nothing to an anonymous viewer" do
      assert_equal SEES_NONE, ask(@post)
    end

    should "show nothing to the posting bot that uploaded it and wrote its private rows" do
      assert_equal @bot.id, FourierTagSource.find_by!(post_id: @post.id, tag: SECRET_TAG).added_by
      assert_equal SEES_NONE, ask(@post, user: @bot)
    end

    # Decision 2026-09-29: a grant is a moderator's row and the creator
    # decides, so no grant opens anything -- of any ability, on the creator's
    # own poster tag or on a tag the post carries. The rows are written as
    # rows already on record: a new view grant cannot be created at all.
    should "show nothing to the holder of any grant, of any ability, on any tag" do
      TagGrant::ABILITIES.product(%w[41chan_alice landscape]).each do |ability, tag|
        TagGrant.new(user: @member, tag: tag, ability: ability).save!(validate: false)
      end
      assert_equal SEES_NONE, ask(@post, user: @member)
    end

    should "show nothing to a member who adds their own poster tag to the post" do
      mallory = create(:user)
      put_auth post_path(@post), mallory, params: { post: { old_tag_string: @post.tag_string, tag_string: "#{@post.tag_string} 41chan_mallory" } }
      assert_includes @post.reload.tag_string.split, "41chan_mallory", "a member could not edit the tags, so this proved nothing"

      assert_equal SEES_NONE, ask(@post, user: mallory, mxid: "@mallory:41chan.net")
      assert_equal SEES_ALL, ask(@post, mxid: CREATOR), "the edit took the post from its creator"
    end
  end

  # A record is keyed by md5 and outlives its post (round-two findings 3 and
  # 13). It is served only while its owner -- the poster it was filed by --
  # is the CURRENT post's recorded creator.
  context "a generation record the post's creator does not own" do
    should "reach nobody through a post re-made from the same bytes after the first was deleted" do
      FourierTagSource.where(post_id: @post.id).delete_all
      meta = @post.media_asset.media_metadata
      Post.where(id: @post.id).delete_all # as expunge! ends; the creator row cascades with it
      refute FourierPostCreator.exists?(post_id: @post.id)
      assert FourierGenerationMetadata.exists?(poster: CREATOR), "the record outlived the post, as in production"

      # A person re-uploads the saved file: its uploader is its creator.
      mallory = create(:user)
      again = make_post(uploader: mallory, poster: nil, meta: meta)
      seen = ask(again, user: mallory)
      assert_equal RECORD_DOORS.index_with(false), seen.slice(*RECORD_DOORS), "the first creator's prompt reached the re-uploader"
      assert seen[:page_tags], "the re-uploader is this post's creator and sees its own private tag"

      # Nor through the tunnel, with the re-uploader recorded as its creator.
      FourierPostCreator.create!(post: again, mxid: "@mallory:41chan.net", recorded_by: @bot.id)
      again.update_columns(uploader_id: @bot.id)
      assert_equal RECORD_DOORS.index_with(false), ask(again, mxid: "@mallory:41chan.net").slice(*RECORD_DOORS)
      assert_equal SEES_NONE, ask(again, mxid: CREATOR), "the first creator is not this post's creator either"
    end

    should "reach nobody when the recorded creator is not the poster the record was filed by" do
      other = make_post(uploader: @bot, poster: "@bob:41chan.net")
      FourierPostCreator.create!(post: other, mxid: CREATOR, recorded_by: @bot.id)

      assert_equal SEES_ALL.merge(RECORD_DOORS.index_with(false)), ask(other, mxid: CREATOR)
      assert_equal SEES_NONE, ask(other, mxid: "@bob:41chan.net")
    end
  end

  context "a post with no recorded creator" do
    # The uploader rule covers the private tags and the image's own
    # metadata. A generation record is only ever filed by the tunnel, owned
    # by an MXID, and served only to a post whose recorded creator owns it --
    # a person's own upload has none, so its record doors stay shut.
    should "treat a person who uploaded it as its creator" do
      person = create(:user)
      own = make_post(uploader: person)

      assert_equal SEES_ALL.merge(RECORD_DOORS.index_with(false)), ask(own, user: person)
      assert_equal SEES_NONE, ask(own, user: create(:admin_user))
      assert_equal SEES_NONE, ask(own, user: @member)
      assert_equal SEES_NONE, ask(own)
    end

    should "show a bot-uploaded one to nobody, not even the identity its tag names" do
      orphan = make_post(uploader: @bot, tags: "41chan_alice landscape")

      assert_equal SEES_NONE, ask(orphan, mxid: CREATOR)
      assert_equal SEES_NONE, ask(orphan, user: @bot)
      assert_equal SEES_NONE, ask(orphan, user: create(:admin_user))
    end
  end
end
