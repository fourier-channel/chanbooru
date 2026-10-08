# frozen_string_literal: true

require "test_helper"

# Releasing a creator from their prefix's default visibility (operator,
# 2026-10-07: "they can then scope visibility according to the individual
# creator tag and not the entire guildtag").
class CreatorTagReleaseTest < ActionDispatch::IntegrationTest
  LIST = <<~YAML
    editors: [tunnel, sample]
    prefixes:
      - {prefix: 4chan_, provenance: Imageboard/web surface, target_kind: site, target: www.4chan.org, scope: x}
      - {prefix: 41chan_, provenance: Matrix, target_kind: server, target: matrix.41chan.net, scope: x}
      - {prefix: aichan_, provenance: Discord, target_kind: server, target: AIChan, scope: x, visible_to: admins}
  YAML

  def status_for(post, user)
    if user
      get_auth(post_path(post, format: :json), user)
    else
      reset!
      get(post_path(post, format: :json))
    end
    response.status
  end

  setup do
    @dir = Dir.mktmpdir("creator-tag-release")
    @path = File.join(@dir, "creator_prefixes.yml")
    @was = ENV.fetch("FOURIER_CREATOR_PREFIXES", nil)
    ENV["FOURIER_CREATOR_PREFIXES"] = @path
    File.write(@path, LIST)
    CreatorPrefixes.reset!
    CreatorTagRelease.reset_cache!

    @tunnel = create(:builder_user, name: "tunnel")
    @member = create(:user)
    @moderator = create(:moderator_user)
    @admin = create(:admin_user)
    @alice = create(:user, name: "alice_owner")
    as(@tunnel) do
      @alices = create(:post, uploader: @tunnel, tag_string: "aichan_alice landscape")
      @bobs = create(:post, uploader: @tunnel, tag_string: "aichan_bob landscape")
    end
    as(@admin) do
      Tag.find_by_name("aichan_alice").update!(category: Tag.categories.artist, updater: @admin)
      @artist = create(:artist, name: "aichan_alice")
    end
    gallery = CreatorGallery.create!(matrix_id: "@alice:41chan.net", slug: "alice-rel", user: @alice)
    ArtistClaim.create!(artist: @artist, creator_gallery: gallery).approve!(by: @admin)
  end

  teardown do
    ENV["FOURIER_CREATOR_PREFIXES"] = @was
    CreatorPrefixes.reset!
    CreatorTagRelease.reset_cache!
    FileUtils.rm_rf(@dir)
  end

  should "show a released creator's posts to everyone, and only theirs" do
    assert_equal 404, status_for(@alices, @member)
    CreatorTagRelease.set!("aichan_alice", released: true, by: @admin, note: "asked in #general")
    assert_equal 200, status_for(@alices, @member)
    assert_equal 200, status_for(@alices, nil)
    assert_equal 404, status_for(@bobs, @member), "releasing one creator released no one else"
  end

  should "let the creator see their own hidden posts, and release them" do
    assert_equal 200, status_for(@alices, @alice), "an approved claimant sees their own"
    assert_equal 404, status_for(@bobs, @alice)
    post_auth update_release_creator_prefixes_path, @alice, params: { tag_name: "aichan_alice", released: "true" }
    assert_equal 200, status_for(@alices, @member)
  end

  should "offer the box on the artist page to the creator, and not to a member" do
    get_auth artist_path(@artist), @alice
    assert_response :success
    assert_select ".creator-release-box input[type=submit][value=?]", "Release my posts"
    get_auth artist_path(@artist), @member
    assert_select ".creator-release-box", false
  end

  should "refuse a member, a moderator, and a creator releasing someone else" do
    [@member, @moderator, @alice].each do |user|
      assert_raises(User::PrivilegeError) { CreatorTagRelease.set!("aichan_bob", released: true, by: user) }
    end
    post_auth update_release_creator_prefixes_path, @member, params: { tag_name: "aichan_bob", released: "true" }
    assert_equal 404, status_for(@bobs, @member)
  end

  # Any unbanned member can rename an Artist. A claim is keyed on the tag it
  # was filed for (ArtistClaim.tag_name, CREATOR_VISIBILITY section 9), so
  # renaming alice's entry to bob's tag hands her neither bob's posts nor the
  # power to release them -- and keeps her own.
  should "not follow a rename of the claimed artist entry" do
    as(@admin) do
      Tag.find_by_name("aichan_bob").update!(category: Tag.categories.artist, updater: @admin)
      @artist.update!(name: "aichan_bob")
    end

    assert_not CreatorTagRelease.may_set?(@alice, "aichan_bob")
    assert_equal Set["aichan_alice"], CreatorTagRelease.owned_names(@alice)
    assert CreatorTagRelease.may_set?(@alice, "aichan_alice")
    assert_equal 404, status_for(@bobs, @alice)
    assert_equal 200, status_for(@alices, @alice)
  end

  # Re-checked at use, as CreatorControl does: a row that no longer satisfies
  # the claim rule (written around the model) confers nothing.
  should "honour no approved claim that fails the claim rule" do
    ArtistClaim.approved.sole.update_columns(tag_name: "aichan_bob") # rubocop:disable Rails/SkipsModelValidations

    assert_not CreatorTagRelease.may_set?(@alice, "aichan_bob")
    assert_empty CreatorTagRelease.owned_names(@alice)
  end

  should "return a creator to the default, keeping the row and who decided" do
    CreatorTagRelease.set!("aichan_alice", released: true, by: @admin)
    CreatorTagRelease.set!("aichan_alice", released: false, by: @admin, note: "asked to be hidden again")
    assert_equal 404, status_for(@alices, @member)
    row = CreatorTagRelease.find_by!(tag_name: "aichan_alice")
    assert_equal [false, @admin.id, "asked to be hidden again"], [row.released, row.updater_id, row.note]
  end

  should "log it for admins only, without naming the creator" do
    CreatorTagRelease.set!("aichan_alice", released: true, by: @admin)
    action = ModAction.where(category: :creator_visibility_update).last
    assert action
    assert_no_match(/aichan_alice/, action.description)
    assert_includes ModAction.visible(@admin), action
    assert_not_includes ModAction.visible(@moderator), action
    assert_not_includes ModAction.visible(@member), action
  end

  should "list hidden creators for an admin, and refuse the page to anyone else" do
    get_auth releases_creator_prefixes_path, @admin
    assert_response :success
    assert_select "td", text: "aichan_alice"
    get_auth releases_creator_prefixes_path, @member
    assert_response 403
  end
end
