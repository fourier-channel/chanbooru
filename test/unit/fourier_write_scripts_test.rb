require "test_helper"

# The two fork scripts that WRITE when given --apply, run as a person runs
# them: the script file itself, with argv. Round-two finding 18: OptionParser
# completes an unambiguous prefix, so -a, --a and --ap each meant --apply and
# wrote. A write is asked for by its whole name, in every script that has one.
#
#   script/fourier_backfill_post_creators.rb
#   script/fourier_remove_private_tags_from_tag_string.rb
class FourierWriteScriptsTest < ActiveSupport::TestCase
  BACKFILL = Rails.root.join("script/fourier_backfill_post_creators.rb").to_s
  CLEANUP = Rails.root.join("script/fourier_remove_private_tags_from_tag_string.rb").to_s
  PREFIXES = [%w[-a], %w[--a], %w[--ap], %w[-- -a], %w[-- --appl]].freeze
  SECRET = "secret_prompt_tag"

  # [exit status, stdout, stderr] of `bin/rails runner <script> <argv>`.
  def run_script(path, *argv)
    status = nil
    saved = ARGV.dup
    ARGV.replace(argv)
    out, err = capture_io do
      load path
    rescue SystemExit => e
      status = e.status
    end
    [status, out, err]
  ensure
    ARGV.replace(saved)
  end

  context "the write scripts" do
    setup do
      # The production posting bots are "sample" and "tunnel" (read from
      # production 2026-09-29): the list is the real one, not a stub.
      @tunnel = create(:builder_user, name: "tunnel")
      @post = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "41chan_alice landscape #{SECRET}") }
      FourierTagSource.record_partition!(@post, { creator: [SECRET], auto: %w[landscape] }, @tunnel)
      PostVersion.where(post_id: @post.id).delete_all
      as(@tunnel) { create(:post_version, post: @post, version: 1, tags: @post.tag_string) }
    end

    should "refuse every abbreviation of --apply in the creator backfill, and write nothing" do
      PREFIXES.each do |argv|
        status, _out, err = run_script(BACKFILL, *argv)

        assert_equal 2, status, argv.inspect
        assert_match(/FAIL: /, err, argv.inspect)
        assert_match(/fix: /, err, argv.inspect)
      end
      assert_equal 0, FourierPostCreator.count
    end

    should "dry-run the creator backfill by default, apply it on --apply, and default to the tunnel's account" do
      status, out, _err = run_script(BACKFILL)
      assert_equal 0, status
      assert_includes out, "PROPOSE\t#{@post.id}\t41chan_alice\t@alice:41chan.net\tyes"
      assert_includes out, "# DRY RUN"
      assert_equal 0, FourierPostCreator.count

      status, out, _err = run_script(BACKFILL, "--", "--apply")
      assert_equal 0, status, out
      assert_equal "@alice:41chan.net", FourierPostCreator.find_by!(post_id: @post.id).mxid
    end

    should "warn loudly about a configured posting bot that matches no account" do
      _status, _out, err = run_script(BACKFILL)

      assert_match(/WARNING: posting bot "sample" .* matches no booru account/, err)
      refute_match(/"tunnel"/, err)
    end

    should "refuse every abbreviation of --apply in the private tag cleanup, and write nothing" do
      PREFIXES.each do |argv|
        status, _out, err = run_script(CLEANUP, *argv)

        assert_equal 2, status, argv.inspect
        assert_match(/fix: /, err, argv.inspect)
      end
      assert_includes @post.reload.tag_array, SECRET
    end

    # The removal is revertible because it is a post version. Where versions
    # are not kept there would be nothing to revert to, so it does not run.
    should "refuse to apply the private tag cleanup where post versions are not kept" do
      PostVersion.stubs(:enabled?).returns(false)
      status, out, err = run_script(CLEANUP, "--", "--apply")

      assert_equal 2, status
      assert_match(/FAIL: post versions are not kept/, err)
      assert_includes out, "POST\t#{@post.id}\t1", "the dry-run listing still prints"
      assert_includes @post.reload.tag_array, SECRET
    end

    should "dry-run the private tag cleanup by default and apply it on --apply, printing no tag" do
      status, out, err = run_script(CLEANUP)
      assert_equal 0, status
      assert_includes out, "POST\t#{@post.id}\t1"
      assert_includes @post.reload.tag_array, SECRET
      refute_includes out + err, SECRET

      status, out, err = run_script(CLEANUP, "--", "--apply")
      assert_equal 0, status, out + err
      assert_includes out, "REMOVED\t#{@post.id}\t1"
      refute_includes out + err, SECRET
      assert_not_includes @post.reload.tag_array, SECRET
    end
  end
end
