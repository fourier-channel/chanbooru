# frozen_string_literal: true

require "test_helper"

# TagGrant: per-user per-tag access, managed from the admin user-edit console.
# ONE ability is granted, "edit", enforced by ArtistClaim.owner?. "view" once
# opened a creator's private tags, and a moderator could grant it to
# themselves; since 2026-09-29 only the creator decides, so no grant of any
# ability opens creator-only data (FourierCreatorPrivacy), and the console no
# longer grants "view" (round-two findings 2 and 17). A grant row is the sole
# way access opens; revoking it closes it again.
class TagGrantsTest < ActionDispatch::IntegrationTest
  # What `user` sees of @granted_post's creator-only data, three doors
  # (the "creator-only data" context below).
  def seen_by(user, headers: {})
    login_as(user) if user
    get post_modulation_path(@granted_post, format: :json), headers: headers
    tags = response.parsed_body["tags"].values.flatten.include?("secret_prompt")
    get "/posts/#{@granted_post.id}/tag_sources.json", headers: headers
    sources = response.body.include?("secret_prompt")
    get post_generation_data_path(@granted_post), headers: headers
    { tags: tags, tag_sources: sources, generation: response.status == 200 }
  end

  context "Tag grants" do
    setup do
      @admin = create(:admin_user)
      @member = travel_to(1.month.ago) { create(:user) }
      @creator = create(:user)
    end

    context "the console" do
      should "grant and revoke from the user-edit page" do
        login_as(@admin)
        post admin_tag_grants_path, params: { user_id: @member.id, tag: "Kokuma Art", ability: "edit" }

        assert_redirected_to edit_admin_user_path(@member)
        grant = TagGrant.find_by!(user_id: @member.id)
        assert_equal("kokuma_art", grant.tag)
        assert_equal("edit", grant.ability)
        assert_equal(@admin.id, grant.granted_by)

        get edit_admin_user_path(@member)
        assert_response :success
        assert_select "#tag-grants", 1
        assert_select "#user-capabilities", 1

        delete admin_tag_grant_path(grant)
        assert_nil(TagGrant.find_by(id: grant.id))
      end

      should "offer only edit, and say in one line why view is not granted" do
        login_as(@admin)
        get edit_admin_user_path(@member)

        assert_response :success
        assert_select "#tag-grants select[name=ability] option", count: 1
        assert_select "#tag-grants select[name=ability] option[value=edit]", 1
        assert_select "#tag-grants p.fineprint", text: /needs a control the creator uses, which does not exist yet/
      end

      # Round-two finding 2: a moderator granted themselves view on a
      # creator's poster tag and read the creator's prompts. The console no
      # longer creates a view grant for anyone, a moderator's own account
      # included, and says why instead.
      should "refuse a view grant, a moderator's own included, and create no row" do
        moderator = create(:moderator_user)
        [[@admin, @member], [moderator, moderator]].each do |granter, grantee|
          login_as(granter)
          post admin_tag_grants_path, params: { user_id: grantee.id, tag: "41chan_alice", ability: "view" }

          assert_redirected_to edit_admin_user_path(grantee)
          assert_match(/Not granted: .*no longer granted.*control the creator uses/, flash[:notice])
        end
        assert_equal 0, TagGrant.count
      end

      should "still list and revoke a view row already on record" do
        grant = TagGrant.new(user: @member, tag: "41chan_alice", ability: "view", granted_by: @admin.id)
        grant.save!(validate: false)
        assert grant.valid?, "a view row on record is still a valid row"

        login_as(@admin)
        get edit_admin_user_path(@member)
        assert_select "#tag-grants .card-outlined", text: /view\s+on\s+41chan_alice/

        delete admin_tag_grant_path(grant)
        assert_nil TagGrant.find_by(id: grant.id)
      end

      should "refuse a non-admin" do
        login_as(@member)
        post admin_tag_grants_path, params: { user_id: @member.id, tag: "x", ability: "edit" }

        assert_response 403
        assert_equal(0, TagGrant.count)
      end
    end

    # No grant opens creator-only data: not view, not edit, not on the
    # creator's own poster tag, not on a tag the post carries (decision
    # 2026-09-29, round-two finding 17). The rows are written as rows already
    # on record, which is the only way a view row can exist now.
    #
    # The posts are the tunnel's shape: each private tag is its sidecar row
    # and is NOT in tag_string (fourier-tunnel 37270f5). Round two's fixture
    # said the opposite, and that fixture is why the creator's own tags were
    # missing from every real post without a test noticing (finding 1).
    context "creator-only data" do
      setup do
        @bot = create(:builder_user, name: "tunnel")
        as(@bot) do
          create(:tag, name: "kokuma", category: TagCategory::ARTIST)
          # A real md5 (the factory's is 64 hex digits), for the record below.
          @granted_post = create(:post, uploader: @bot, tag_string: "41chan_alice kokuma plain", md5: SecureRandom.hex(16))
          @other_post = create(:post, uploader: @bot, tag_string: "41chan_bob kokuma plain")
          FourierTagSource.record_partition!(@granted_post, { creator: ["secret_prompt"] }, @bot)
          FourierTagSource.record_partition!(@other_post, { creator: ["other_secret"] }, @bot)
        end
        FourierPostCreator.create!(post: @granted_post, mxid: "@alice:41chan.net", recorded_by: @bot.id)
        FourierPostCreator.create!(post: @other_post, mxid: "@bob:41chan.net", recorded_by: @bot.id)
        FourierGenerationMetadata.create!(md5: @granted_post.md5, raw_md5: SecureRandom.hex(16), source: "matrix",
                                          poster: "@alice:41chan.net", fields: { "png:parameters" => "alice secret prompt" })
      end

      should "open it to its creator, which proves the doors can open" do
        assert_equal({ tags: true, tag_sources: true, generation: true }, seen_by(nil, headers: { "X-Fourier-Identity" => "@alice:41chan.net" }))
      end

      should "open nothing through a grant of any ability on the creator's own poster tag or any tag the post carries" do
        TagGrant::ABILITIES.each do |ability|
          %w[41chan_alice kokuma plain].each do |tag|
            TagGrant.new(user: @member, tag: tag, ability: ability, granted_by: @admin.id).save!(validate: false)
          end
        end
        assert_equal TagGrant::ABILITIES.sort, TagGrant.where(user: @member).distinct.pluck(:ability).sort

        assert_equal({ tags: false, tag_sources: false, generation: false }, seen_by(@member))
      end

      should "open nothing to a moderator who granted themselves view before the console stopped offering it" do
        moderator = create(:moderator_user)
        TagGrant.new(user: moderator, tag: "41chan_alice", ability: "view", granted_by: moderator.id).save!(validate: false)

        assert_equal({ tags: false, tag_sources: false, generation: false }, seen_by(moderator))
      end
    end

    context "the edit gate" do
      should "confer artist ownership through an edit grant, until revoked" do
        artist = as(@creator) { create(:artist, name: "kokuma") }
        assert_not(ArtistClaim.owner?(@member, artist))

        grant = TagGrant.create!(user: @member, tag: "kokuma", ability: "edit", granted_by: @admin.id)
        assert(ArtistClaim.owner?(@member, artist))

        grant.destroy!
        assert_not(ArtistClaim.owner?(@member, artist))
      end
    end
  end
end
