# frozen_string_literal: true

require "test_helper"

# TagGrant: per-user per-tag access, managed from the admin user-edit console
# and enforced at the two gates that already exist -- FourierTagSource's
# privacy gate (view) and ArtistClaim.owner? (edit). A grant row is the sole
# way access opens; revoking it closes it again.
class TagGrantsTest < ActionDispatch::IntegrationTest
  context "Tag grants" do
    setup do
      @admin = create(:admin_user)
      @member = travel_to(1.month.ago) { create(:user) }
      @creator = create(:user)
    end

    context "the console" do
      should "grant and revoke from the user-edit page" do
        login_as(@admin)
        post admin_tag_grants_path, params: { user_id: @member.id, tag: "Kokuma Art", ability: "view" }

        assert_redirected_to edit_admin_user_path(@member)
        grant = TagGrant.find_by!(user_id: @member.id)
        assert_equal("kokuma_art", grant.tag)
        assert_equal(@admin.id, grant.granted_by)

        get edit_admin_user_path(@member)
        assert_response :success
        assert_select "#tag-grants", 1
        assert_select "#user-capabilities", 1

        delete admin_tag_grant_path(grant)
        assert_nil(TagGrant.find_by(id: grant.id))
      end

      should "refuse a non-admin" do
        login_as(@member)
        post admin_tag_grants_path, params: { user_id: @member.id, tag: "x", ability: "edit" }

        assert_response 403
        assert_equal(0, TagGrant.count)
      end
    end

    context "the view gate" do
      should "open private creator tags on granted-tag posts, and only those" do
        as(@creator) do
          create(:tag, name: "kokuma", category: TagCategory::ARTIST)
          @granted_post = create(:post, tag_string: "kokuma plain")
          @other_post = create(:post, tag_string: "plain")
          FourierTagSource.record_partition!(@granted_post, { creator: ["secret_prompt"] }, @creator)
          FourierTagSource.record_partition!(@other_post, { creator: ["other_secret"] }, @creator)
        end
        TagGrant.create!(user: @member, tag: "kokuma", ability: "view", granted_by: @admin.id)

        login_as(@member)
        get post_modulation_path(@granted_post, format: :json)
        assert_includes(response.parsed_body["tags"].values.flatten, "secret_prompt")

        get post_modulation_path(@other_post, format: :json)
        assert_not_includes(response.parsed_body["tags"].values.flatten, "other_secret")
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
