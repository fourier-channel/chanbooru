require "test_helper"

# The booru-side jailings from before 2026-10-10, brought into the report to
# the jail panel and, for the pill's, made releasable from it
# (FourierPastJailings; operator 2026-10-09: every booru-side jailing
# reaches the panel, and the panel is the only door out).
class FourierPastJailingsTest < ActiveSupport::TestCase
  JAIL = "troll_jail"

  setup do
    @moderator = create(:moderator_user)
    @bot = create(:approver_user, name: "sample")
  end

  # The pill before 2026-10-10: the tag, then the deletion AS THE MODERATOR.
  # The tag is written past the save callbacks, as it stood then: today the
  # booru reports a tagged post's deletion itself (Post#report_jailing_entered).
  def old_pill_jailing
    post = create(:post, tag_string: "landscape")
    as(@moderator) { post.delete!(FourierPastJailings::PILL_REASON, user: @moderator) }
    post.update_columns(tag_string: "landscape #{JAIL}") # rubocop:disable Rails/SkipsModelValidations -- past the callbacks, as it stood then
    post.reload
  end

  # The old pill's jail-on of a post a moderator had already deleted: the
  # tag alone, no deletion of its own and no report.
  def old_tag_only_jailing
    post = create(:post, tag_string: "landscape")
    as(@moderator) { post.delete!("duplicate", user: @moderator) }
    post.update_columns(tag_string: "landscape #{JAIL}") # rubocop:disable Rails/SkipsModelValidations -- past the callbacks, as it stood then
    post.reload
  end

  # The banished-tag failsafe before 2026-10-10: deleted by the system user,
  # logged, but no post_jail row.
  def old_banished_jailing
    post = create(:post, tag_string: "landscape #{JAIL}")
    CurrentUser.scoped(User.system) { post.delete!("troll jail: banished tag", user: User.system) }
    ModAction.log("deleted post ##{post.id}, reason: troll jail: banished tag", :post_delete, subject: post, user: User.system)
    post.reload
  end

  context "Past booru-side jailings" do
    should "be planned when standing and unreported, and nothing else" do
      pill = old_pill_jailing
      banished = old_banished_jailing
      ordinary = create(:post, tag_string: "landscape")
      as(@moderator) { ordinary.delete!("duplicate", user: @moderator) }
      sampled = create(:post, tag_string: "landscape #{JAIL}")
      as(@bot) { sampled.delete!("troll jail: shock", user: @bot) }
      reported = create(:post, tag_string: "landscape")
      reported.jail_by_booru!("troll jail: banished tag")

      assert_equal([[banished.id, :banished], [pill.id, :pill]], FourierPastJailings.plan.map { |post, _row, kind| [post.id, kind] })
    end

    should "make the pill's releasable and both reported, writing nothing twice" do
      pill = old_pill_jailing
      banished = old_banished_jailing
      assert_not pill.deletion_is_the_jails?

      assert_equal(2, FourierPastJailings.apply!(FourierPastJailings.plan))

      assert pill.reload.deletion_is_the_jails?
      assert banished.reload.deletion_is_the_jails?
      jailed = ModAction.where(category: :post_jail, creator: User.system).pluck(:subject_id, :description)
      assert_includes(jailed, [pill.id, "jailed post ##{pill.id}, reason: troll jail: moderator #{@moderator.name}, from the post page"])
      assert_includes(jailed, [banished.id, "jailed post ##{banished.id}, reason: troll jail: banished tag"])
      assert_equal([], FourierPastJailings.plan)
    end

    # The old pill's jail-off took the tag and left the post deleted: a
    # moderator's decision that it was no longer jailed, never re-jailed here.
    should "pass a pill jailing whose tag a moderator took off" do
      pill = old_pill_jailing
      pill.update_columns(tag_string: "landscape") # rubocop:disable Rails/SkipsModelValidations -- the old pill's jail-off, as it stood then

      assert_equal([], FourierPastJailings.plan)
    end

    should "report a tag-only jailing, so the panel can release it" do
      tagged = old_tag_only_jailing
      assert tagged.jailed?

      assert_equal([[tagged.id, :tagged]], FourierPastJailings.plan.map { |post, _row, kind| [post.id, kind] })
      assert_equal(1, FourierPastJailings.apply!(FourierPastJailings.plan))

      assert tagged.reload.jailing_stands?
      assert_not tagged.deletion_is_the_jails?
      assert_equal([], FourierPastJailings.plan)
    end

    # Undone, then deleted again for another reason: the deletion standing is
    # not the pill's, and is never made the jail's.
    should "pass a jailing undone since" do
      pill = old_pill_jailing
      admin = create(:admin_user)
      as(admin) { pill.update!(is_deleted: false) }
      ModAction.log("undeleted post ##{pill.id}", :post_undelete, subject: pill, user: admin)
      as(@moderator) { pill.reload.delete!("duplicate", user: @moderator) }

      assert_equal([], FourierPastJailings.plan)
    end
  end
end
