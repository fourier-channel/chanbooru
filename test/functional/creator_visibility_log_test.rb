# frozen_string_literal: true

require "test_helper"

# THE PANEL'S LOG: read by admins alone, and readable by them (design
# CREATOR_VISIBILITY Q2, ruled 2026-10-07: moderators see nothing a creator
# hid, nor who a creator let in). Every admin-only category is written here
# through its real write path, then read through every door that lists mod
# actions: /mod_actions, which renders a link to each row's subject (so a
# subject with no route is a 500 for the admin), and /reports/mod_actions,
# which counts rows by any search and must not count these for anyone else.
class CreatorVisibilityLogTest < ActionDispatch::IntegrationTest
  setup do
    CreatorPrefixes.reset!
    @tunnel = create(:builder_user, name: "tunnel")
    @admin = create(:admin_user)
    @maple = create(:user)
    @member = create(:user)
    @gallery = CreatorGallery.create!(matrix_id: "@maple:41chan.net", slug: "maple", user: @maple)
    @post = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "landscape") }
    FourierPostCreator.create!(post: @post, mxid: "@maple:41chan.net", recorded_by: @tunnel.id)

    tier = CreatorGroup.make!(@gallery, name: "41chan_maple_tier_1", tier: 1, by: @maple)
    tier.add_member!(@member, by: @maple)
    tier.remove_member!(@member, by: @maple)
    tier.open_to_requests!(true, by: @maple)
    CreatorJoinRequest.file!(tier, @member).approve!(by: @maple)
    CreatorJoinRequest.file!(tier, create(:user)).reject!(by: @maple, note: "not yet")
    @gallery.set_default_audience!("groups", by: @maple, group_ids: [tier.id])
    CreatorPostAudience.set!(@post, gallery: @gallery, audience: "private", by: @maple)
    CreatorUserRule.set!(@gallery, @member, rule: "block", by: @maple)
    CreatorGroup.make!(@gallery, name: "41chan_maple_friends", by: @maple).dissolve!(by: @maple)

    artist = as(@admin) { create(:artist, name: "aichan_maple") }
    ArtistClaim.create!(artist: artist, creator_gallery: @gallery).approve!(by: @admin)
    ArtistClaim.create!(artist: as(@admin) { create(:artist, name: "4chan_maple") }, creator_gallery: @gallery).reject!(by: @admin)
    CreatorTagRelease.set!("aichan_maple", released: true, by: @admin)
    ModAction.log("unlinked the booru account of creator page maple", :creator_gallery_unlink, subject: @gallery, user: @admin)
    # The flagged-tag review queue (operator, 2026-10-12): flag, release and
    # banish, through their real write paths.
    as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "under_review sent_away") }
    TagQuarantine.flag!(Tag.find_by_name("under_review"), by: @admin, note: "check it").release!(by: @admin, note: "fine")
    TagQuarantine.flag!(Tag.find_by_name("sent_away"), by: @admin).banish!(by: @admin, note: "not here")
    # Unbanished from sampling's jail panel (operator, 2026-10-12): a tag no
    # longer banished, so its rows -- the unbanish among them -- show again.
    as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "came_back") }
    TagQuarantine.flag!(Tag.find_by_name("came_back"), by: @admin).banish!(by: @admin)
    TagQuarantine.find_by!(tag: Tag.find_by_name("came_back")).unbanish!(by: @tunnel, panel_user: "@saber:41chan.net", note: "reviewed")
    # Q2's view log, through its real door: an admin opening the page of a
    # post its creator made private (stage 3, 2026-10-08).
    get_auth post_path(@post), @admin
  end

  should "write every admin-only category" do
    assert_equal(ModAction::ADMIN_ONLY_CATEGORIES.map(&:to_s).sort, ModAction.distinct.pluck(:category).sort & ModAction::ADMIN_ONLY_CATEGORIES.map(&:to_s))
  end

  # Every row about a tag banished NOW -- its banish row and its earlier flag
  # row -- is shown to nobody but the pipeline, admins included (operator,
  # 2026-10-12: "the booru itself will never be the surface that shows
  # banished tags, ever"; sampling's jail panel is that surface).
  def rows_about_banished_tags
    ModAction.where(subject_type: "Tag", subject_id: TagQuarantine.where(state: "banished").select(:tag_id))
  end

  should "render every one of them, with its links, for an admin -- but nothing about a banished tag" do
    get_auth mod_actions_path(limit: 100), @admin

    assert_response :success
    assert_equal(2, rows_about_banished_tags.count, "sent_away's flag and banish rows exist")
    sent_away = Tag.find_by_name("sent_away")
    assert_no_match(/sent_away|banished tag ##{sent_away.id}\b/, response.body, "nothing about the tag banished now")
    assert_match(/came_back/, response.body, "an unbanished tag's rows show again")
    ModAction::ADMIN_ONLY_CATEGORIES.each do |category|
      assert_select "a[href=?]", mod_actions_path(search: { category: category.to_s }), { minimum: 1 }, "no row of #{category}"
    end
  end

  should "count none of them in the mod actions report for anyone but an admin" do
    admin_only = ModAction.where(category: ModAction::ADMIN_ONLY_CATEGORIES).count
    everything = ModAction.count

    [[@admin, everything - rows_about_banished_tags.count], [create(:moderator_user), everything - admin_only], [@member, everything - admin_only], [nil, everything - admin_only]].each do |viewer, expected|
      if viewer
        get_auth report_path("mod_actions", search: { mode: "table" }, format: :json), viewer
      else
        get report_path("mod_actions", search: { mode: "table" }, format: :json)
      end

      assert_response :success
      assert_equal([{ "mod_actions" => expected }], response.parsed_body, viewer&.name || "signed out")
    end
  end
end
