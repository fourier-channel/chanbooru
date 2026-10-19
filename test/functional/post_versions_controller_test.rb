require "test_helper"

class PostVersionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = create(:user)

    as(@user) do
      @post = create(:post, tag_string: "tagme", rating: "s", source: "http://blah.com")
      travel(2.hours) { @post.update(tag_string: "1 2", source: "http://xxx.com") }
      travel(4.hours) { @post.update(tag_string: "2 3", rating: "e") }
      @post2 = create(:post)
    end
  end

  context "The post versions controller" do
    context "index action" do
      should "list all versions" do
        get_auth post_versions_path, @user
        assert_response :success
        assert_select "#post-version-#{@post.versions[0].id}"
        assert_select "#post-version-#{@post.versions[1].id}"
        assert_select "#post-version-#{@post.versions[2].id}"
      end

      should "list all versions that match the search criteria" do
        get_auth post_versions_path, @user, params: { search: { post_id: @post.id }}
        assert_response :success
        assert_select "#post-version-#{@post2.versions[0].id}", false
      end

      should "list all versions for search[changed_tags]" do
        get post_versions_path(search: { changed_tags: "1" }), as: :json
        assert_response :success
        assert_equal @post.versions[1].id, response.parsed_body[1]["id"].to_i
        assert_equal @post.versions[2].id, response.parsed_body[0]["id"].to_i

        get post_versions_path(search: { changed_tags: "1 2" }), as: :json
        assert_response :success
        assert_equal @post.versions[1].id, response.parsed_body[0]["id"].to_i
      end

      should "list all versions for search[tag_matches]" do
        get post_versions_path(search: { tag_matches: "tagme" }), as: :json
        assert_response :success
        assert_equal @post.versions[0].id, response.parsed_body[0]["id"].to_i
        assert_equal 1, response.parsed_body.length
      end
    end

    context "undo action" do
      should "undo the edit" do
        put_auth undo_post_version_path(@post.versions.second), @user
        assert_response :redirect
        assert_equal("e", @post.reload.rating)
        assert_equal("3 tagme", @post.tag_string)
        assert_equal("http://blah.com", @post.source)
      end

      should "not allow non-members to undo edits" do
        put undo_post_version_path(@post.versions.first)
        assert_response 403
        assert_equal("2 3", @post.reload.tag_string)
      end
    end

    # Fork: BUR review 2026-10-19, M2. Undoing FourierPrivateTagCleanup's
    # edit would put a creator's private prompt tag, which the posting bot
    # leaked, back on the public list under the member's name -- a member
    # who cannot see what they restored, since history withholds it.
    context "undo action, for the private-tag cleanup" do
      setup do
        @tunnel = create(:builder_user, name: "tunnel")
        @admin = create(:admin_user)
        as(@tunnel) { @leaked = create(:post, uploader: @tunnel, tag_string: "41chan_alice landscape secret_prompt_tag") }
        FourierTagSource.record_partition!(@leaked, { creator: %w[secret_prompt_tag], auto: %w[landscape] }, @tunnel)
        FourierPostCreator.create!(post: @leaked, mxid: "@alice:41chan.net", recorded_by: @tunnel.id)
        FourierPrivateTagCleanup.apply!(FourierPrivateTagCleanup.plan, user: @admin)
        @leaked.reload
        @cleanup = @leaked.versions.order(:version).last
        assert_equal(["secret_prompt_tag"], @cleanup.removed_tags, "fixture: the cleanup's own version")
      end

      should "refuse a member's undo of the private-tag cleanup" do
        put_auth undo_post_version_path(@cleanup, format: :json), @user

        assert_response 422
        assert_equal("41chan_alice landscape", @leaked.reload.tag_string)
        assert_equal("This version would put back 1 tag(s) only the post's creator may publish; add any tag you mean by hand.", response.parsed_body["message"])
        assert_not_includes(response.body, "secret_prompt_tag")
      end

      should "let the creator undo it" do
        put_auth undo_post_version_path(@cleanup), create(:user), headers: { "X-Fourier-Identity" => "@alice:41chan.net" }

        assert_response :redirect
        assert_includes(@leaked.reload.tag_array, "secret_prompt_tag")
      end

      should "undo a person's removal of a tag a person added" do
        as(@user) { @leaked.update!(tag_string: "41chan_alice landscape secret_prompt_tag") }
        as(@admin) { travel(2.hours) { @leaked.update!(tag_string: "41chan_alice landscape") } }

        put_auth undo_post_version_path(@leaked.versions.order(:version).last), create(:user)

        assert_response :redirect
        assert_includes(@leaked.reload.tag_array, "secret_prompt_tag")
      end
    end
  end
end
