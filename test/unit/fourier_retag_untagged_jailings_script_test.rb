# frozen_string_literal: true

require "test_helper"

# script/fourier_retag_untagged_jailings.rb (boo.122 residual, 2026-11-20):
# puts troll_jail back on each post in Post.untagged_jailed_ids through
# Post#add_jail_tag! as the system user, a dry run by default, writing only
# with --apply, with n/N progress, and printing ids and counts, never tags.
class FourierRetagUntaggedJailingsScriptTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("script/fourier_retag_untagged_jailings.rb").to_s
  JAIL = "troll_jail"
  SECRET = "secret_prompt_tag"

  # A script that runs to its end exits 0 under rails runner.
  def run_script(*argv)
    status = 0
    saved = ARGV.dup
    ARGV.replace(argv)
    out, err = capture_io do
      load SCRIPT
    rescue SystemExit => e
      status = e.status
    end
    [status, out, err]
  ensure
    ARGV.replace(saved)
  end

  context "the untagged-jailing re-tag" do
    setup do
      @admin = create(:admin_user)
      @sample = create(:approver_user, name: "sample")
      @uploader = create(:contributor_user)

      # Jailed by the panel's account (the tag, then the deletion), then the
      # tag lost through an ordinary save, as the tagger's race lost it.
      @raced = as(@uploader) { create(:post, uploader: @uploader, tag_string: "landscape #{SECRET}") }
      as(@sample) { @raced.update!(tag_string: "landscape #{SECRET} #{JAIL}") }
      @raced.reload.delete!("troll jail: shock", user: @sample)
      as(@sample) { @raced.reload.update!(tag_string: "landscape #{SECRET}") }

      # Deleted by hand, then reported to the booru as a jailing.
      @reported = as(@uploader) { create(:post, uploader: @uploader, tag_string: "landscape") }
      @reported.delete!("duplicate", user: @admin)
      ModAction.log("jailed post ##{@reported.id}, reason: troll jail: reported", :post_jail, subject: @reported, user: User.system)

      # Controls: an ordinary deletion and a jailed post that kept its tag.
      @deleted = as(@uploader) { create(:post, uploader: @uploader, tag_string: "landscape") }
      @deleted.delete!("duplicate", user: @admin)
      @tagged = as(@uploader) { create(:post, uploader: @uploader, tag_string: "landscape") }
      as(@sample) { @tagged.update!(tag_string: "landscape #{JAIL}") }
      @tagged.reload.delete!("troll jail: shock", user: @sample)

      assert_equal [@raced.id, @reported.id].sort, Post.untagged_jailed_ids_now, "fixture: exactly the two untagged jailings"
    end

    should "refuse an abbreviation of --apply and write nothing" do
      [%w[-a], %w[--ap], %w[-- --appl]].each do |argv|
        status, _out, err = run_script(*argv)
        assert_equal 2, status, argv.inspect
        assert_match(/fix: /, err)
      end
      assert_equal 2, Post.untagged_jailed_ids_now.size
    end

    should "dry-run by default: list the posts by id with n/N progress, and write nothing" do
      status, out, _err = run_script

      assert_equal 0, status
      assert_includes out, "2 jailed post(s) without #{JAIL} -- DRY RUN"
      assert_includes out, "1/2\tpost ##{[@raced.id, @reported.id].min}\twould be re-tagged"
      assert_includes out, "2/2\tpost ##{[@raced.id, @reported.id].max}\twould be re-tagged"
      assert_not_includes out, SECRET
      assert_not @raced.reload.has_tag?(JAIL)
      assert_not @reported.reload.has_tag?(JAIL)
    end

    should "re-tag each one on --apply as the system user, and leave everything else" do
      # Jailed by the log alone (Post.jail_deletions) while the newest flag is
      # not the jail's: the one shape whose re-tag the booru reported to the
      # jail feed as a new jailing, until a jail account's tagging was skipped.
      @raced.flags.succeeded.order(:id).last.update_columns(reason: "duplicate")
      reports = -> { ModAction.where(category: "post_jail", subject: [@raced, @reported]).count }
      reports_before = reports.call
      versions = PostVersion.where(post_id: [@raced.id, @reported.id]).count
      status, out, _err = run_script("--", "--apply")

      assert_equal 0, status, out
      assert_includes out, "1/2\tpost #"
      assert_includes out, "2/2\tpost #"
      assert_includes out, "re-tagged 2 of 2; 0 failed; 0 jailed post(s) still without #{JAIL}; 0 new jailing report(s)"
      assert_equal reports_before, reports.call, "the re-tag is the jail acting: nothing reaches the jail feed"
      assert_not_includes out, SECRET
      assert_equal [], Post.untagged_jailed_ids_now

      [@raced, @reported].each do |post|
        post.reload
        assert post.has_tag?(JAIL), "post ##{post.id}"
        assert post.is_deleted?, "post ##{post.id} stays deleted"
        assert post.jailed?, "post ##{post.id} stays jailed"
        assert_equal User.system.id, PostVersion.where(post_id: post.id).order(:id).last.updater_id if PostVersion.where(post_id: post.id).exists?
      end
      assert_includes @raced.tag_array, SECRET
      assert PostVersion.where(post_id: [@raced.id, @reported.id]).count >= versions
      assert_not @deleted.reload.has_tag?(JAIL)
      assert @tagged.reload.has_tag?(JAIL)

      # Run again: nothing left to do.
      status, out, _err = run_script("--", "--apply")
      assert_equal 0, status
      assert_includes out, "0 jailed post(s) without #{JAIL}"
    end

    should "fail loudly, by id and with the fix, when the tag does not land" do
      Post.any_instance.stubs(:add_jail_tag!).raises(ActiveRecord::RecordNotSaved.new("post: #{JAIL} did not land"))
      status, out, err = run_script("--", "--apply")

      assert_equal 1, status
      assert_includes out, "FAILED: post: #{JAIL} did not land"
      assert_includes out, "re-tagged 0 of 2; 2 failed; 2 jailed post(s) still without #{JAIL}"
      assert_match(/fix: /, err)
    end
  end
end
