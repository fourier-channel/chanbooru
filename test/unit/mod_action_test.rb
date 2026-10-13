require "test_helper"

class ModActionTest < ActiveSupport::TestCase
  context "A mod action" do
    setup do
      @user = create(:user)
      @mod = create(:moderator_user)
    end

    should "hide ip addresses from non-moderators in ip ban modactions" do
      as(@mod) { create(:ip_ban, ip_addr: "1.1.1.1", reason: "test") }

      assert_equal(0, ModAction.visible(@user).count)
      assert_equal(1, ModAction.visible(@mod).count)
    end

    should "hide backup code send actions from non-moderators" do
      create(:mod_action, category: "backup_code_send")

      assert_equal(0, ModAction.visible(@user).count)
      assert_equal(1, ModAction.visible(@mod).count)
    end

    should "hide email address update actions from non-moderators" do
      create(:mod_action, category: "email_address_update")

      assert_equal(0, ModAction.visible(@user).count)
      assert_equal(1, ModAction.visible(@mod).count)
    end

    # The review queue's rows (TagQuarantine): admins only, and a row about a
    # tag that is banished now is shown to nobody but the pipeline -- an admin
    # never sees a banished name, not even in an old flag row.
    should "show the review queue's rows to admins alone, and hide a banished tag's from them too" do
      admin = create(:admin_user)
      tag = create(:tag, name: "queued_thing")
      row = TagQuarantine.flag!(tag, by: admin, note: "")

      assert_equal(1, ModAction.visible(admin).where(category: "tag_flag").count)
      assert_equal(0, ModAction.visible(@mod).where(category: "tag_flag").count)
      assert_equal(0, ModAction.visible(@user).where(category: "tag_flag").count)

      row.banish!(by: admin, note: "")
      assert_equal(0, ModAction.visible(admin).where(category: %w[tag_flag tag_banish]).count)
      assert_equal(2, ModAction.where(category: %w[tag_flag tag_banish]).count, "the rows are kept")
    end

    # An artist claim's decision names the creator tag, with the ARTIST
    # entry as its subject: admins read that category, and an admin never
    # sees a banished name (review pass 2026-10-12).
    should "keep a row whose subject artist names a banished tag from an admin" do
      admin = create(:admin_user)
      create(:tag, name: "banished_painter", category: Tag.categories.artist)
      artist = as(admin) { create(:artist, name: "banished_painter") }
      row = ModAction.log("approved the claim of @x:41chan.net on creator tag banished_painter", :artist_claim_approve, subject: artist, user: admin)
      assert_includes ModAction.without_hidden_posts(admin).pluck(:id), row.id

      TagQuarantine.create!(tag: Tag.find_by_name!("banished_painter"), state: TagQuarantine::BANISHED, banished_by: admin, banished_at: Time.zone.now)
      CreatorVisibility.forget!
      assert_not_includes ModAction.without_hidden_posts(admin).pluck(:id), row.id
      assert row.hidden_by_post_from?(admin)
    end
  end
end
