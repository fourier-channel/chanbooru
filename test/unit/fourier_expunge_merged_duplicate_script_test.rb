# frozen_string_literal: true

require "test_helper"

# script/fourier_expunge_merged_duplicate.rb (operator, 2026-10-16: expunge the
# seven retired Matrix duplicates, one post at a time, with the proof): it
# refuses anything but a retired merge child; it DELETES (never trashes) every
# object of the post's media asset that exists plus canon's moved-aside raw
# upload, skipping an absent one; it removes the post record as Post#expunge!
# does; and it ends by asking for every key again. R2 is stood in for by a set
# of present targets behind a fake rclone.
class FourierExpungeMergedDuplicateScriptTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("script/fourier_expunge_merged_duplicate.rb").to_s
  MERGE = Rails.root.join("script/fourier_merge_matrix_duplicates.rb").to_s

  # The storage manager's surface the script uses, over a set of present keys.
  class FakeStorage
    attr_reader :present, :deleted
    # [stderr, exit status] lsjson answers for a key not present, instead of
    # 1.60's empty "directory".
    attr_accessor :lsjson_failure

    def initialize = (@present = Set.new) && (@deleted = [])
    def remote = "r2"
    def bucket = "bucket"
    def rclone_path = "rclone"
    def rclone_options = []
    def fourier_key(path) = path.sub(%r{\A/(original|sample|180x180|360x360|720x720)/\w{2}/\w{2}/(sample-)?}, "keyed/\\1/")
    def key(path) = ":r2:bucket/#{fourier_key(path)}"
    def file_url(path) = "https://example.com/data#{path}"
  end

  def run_script(script, *argv)
    status = nil
    saved = ARGV.dup
    ARGV.replace(argv)
    out, err = capture_io do
      load script
    rescue SystemExit => e
      status = e.status
    end
    [status, out, err]
  ensure
    ARGV.replace(saved)
  end

  # Open3.capture3 is a module function -- itself a singleton method of Open3 --
  # so the fake REPLACES it and teardown puts the original back; removing the
  # fake would remove capture3 for every later test in the worker.
  def fake_rclone(storage)
    @real_capture3 = Open3.method(:capture3)
    Open3.define_singleton_method(:capture3) do |*args|
      target = args[-1]
      if args.include?("lsjson")
        # As rclone 1.60 answers: an object has IsDir false and a size; a
        # key with no object behind it SUCCEEDS as an empty "directory".
        if storage.present.include?(target)
          ["{\"Path\":\"x\",\"Size\":7310,\"IsDir\":false}", "", Struct.new(:success?, :exitstatus).new(true, 0)]
        elsif storage.lsjson_failure
          err, code = storage.lsjson_failure
          ["", err, Struct.new(:success?, :exitstatus).new(false, code)]
        else
          ["{\"Path\":\"\",\"Size\":-1,\"IsDir\":true}", "", Struct.new(:success?, :exitstatus).new(true, 0)]
        end
      elsif args.include?("deletefile")
        storage.present.delete(target)
        storage.deleted << target
        ["", "", Struct.new(:success?, :exitstatus).new(true, 0)]
      else
        raise "unexpected rclone call #{args.inspect}"
      end
    end
  end

  setup do
    @admin = create(:admin_user, name: "boss")
    @tunnel = create(:builder_user, name: "tunnel")
    @sample = create(:builder_user, name: "sample")
    @mxc = "mxc://41chan.net/abcdEFGHijklMNOP"
    @retired = as(@tunnel) { create(:post, uploader: @tunnel, md5: SecureRandom.hex(16), tag_string: "landscape", source: @mxc) }
    @survivor = as(@sample) { create(:post, uploader: @sample, md5: SecureRandom.hex(16), tag_string: "landscape", source: "https://boards.4chan.org/b/thread/1") }
    status, out, = run_script(MERGE, "--", "--as", "boss", "--pair", "#{@retired.id}:#{@survivor.id}", "--apply")
    assert_nil(status, out)
    assert @retired.reload.is_deleted?

    @storage = FakeStorage.new
    Danbooru.config.stubs(:storage_manager).returns(@storage)
    # The thumbnails are present, the original is not (canon moved it aside),
    # and canon's raw upload sits under superseded/.
    @retired.media_asset.variants.each { |v| @storage.present << @storage.key(v.file_path) unless v.type == :original }
    @raw = ":r2:bucket/superseded/local_content/ab/cd/EFGHijklMNOP"
    @storage.present << @raw
    @before = @storage.present.dup
    fake_rclone(@storage)
  end

  teardown do
    Open3.define_singleton_method(:capture3, @real_capture3) if @real_capture3
  end

  should "on a dry run list every key and its state, and change nothing" do
    status, out, = run_script(SCRIPT, "--", "--post", @retired.id.to_s, "--as", "boss")

    assert_nil(status, out)
    assert_match(%r{superseded/local_content/ab/cd/EFGHijklMNOP: present -- would delete}, out)
    assert_match(%r{keyed/original/.*: absent}, out)
    assert_match(/dry run: nothing written/, out)
    assert_equal(@before, @storage.present)
    assert_empty(@storage.deleted)
    assert Post.exists?(@retired.id)
  end

  should "on --apply delete every present object, skip the absent original, remove the record, and prove it" do
    status, out, = run_script(SCRIPT, "--", "--post", @retired.id.to_s, "--as", "boss", "--apply")

    assert_nil(status, out)
    assert_empty(@storage.present, "every present object deleted")
    assert_equal(@before.sort, @storage.deleted.sort, "only what was present, each once; the absent original never deleted")
    assert_not Post.exists?(@retired.id)
    assert_equal "expunged", @retired.media_asset.reload.status
    assert_match(/after: every key must be ABSENT/, out)
    assert_no_match(/PRESENT/, out)
    assert_match(/done: post ##{@retired.id} expunged, #{@before.size} object\(s\) deleted/, out)
    assert ModAction.where(category: "post_permanent_delete").last.description.include?("merged into post ##{@survivor.id}")
    assert Post.find(@survivor.id).present?
  end

  # Without a config file rclone opens EVERY answer with this notice, so the
  # words "not found" on stderr say nothing about the object.
  CONFIG_NOTICE = "NOTICE: Config file \"/home/danbooru/.config/rclone/rclone.conf\" not found - using defaults\n"

  should "count a key as absent when rclone answers not found, as 1.75 does" do
    @storage.lsjson_failure = ["#{CONFIG_NOTICE}NOTICE: Failed to lsjson: directory not found\n", 3]
    status, out, = run_script(SCRIPT, "--", "--post", @retired.id.to_s, "--as", "boss")

    assert_nil(status, out)
    assert_match(%r{keyed/original/.*: absent}, out)
    assert_match(%r{superseded/local_content/ab/cd/EFGHijklMNOP: present -- would delete}, out)
  end

  should "stop, naming rclone's reason, when it cannot say whether a key is there" do
    @storage.lsjson_failure = ["#{CONFIG_NOTICE}ERROR : Attempt 1/3 failed with 1 errors and: AccessDenied: Access Denied\nNOTICE: Failed to lsjson: AccessDenied: Access Denied\n", 1]
    error = assert_raises(RuntimeError) { run_script(SCRIPT, "--", "--post", @retired.id.to_s, "--as", "boss", "--apply") }

    assert_match(/lsjson --stat .* failed: .*AccessDenied/m, error.message)
    assert_no_match(/Config file/, error.message)
    assert Post.exists?(@retired.id), "the record stays until every key has been answered"
  end

  should "refuse anything but a retired merge child, naming the fix" do
    live = as(@sample) { create(:post, uploader: @sample, md5: SecureRandom.hex(16), tag_string: "landscape") }
    [@survivor.id, live.id, 999_999_999].each do |id|
      status, _out, err = run_script(SCRIPT, "--", "--post", id.to_s, "--as", "boss", "--apply")
      assert_equal(1, status, id)
      assert_match(/REFUSED/, err)
      assert_match(/fix: /, err)
    end
    assert_empty(@storage.deleted)
  end

  should "refuse a post deleted for another reason" do
    @retired.flags.each { |flag| flag.update!(reason: "something else") }
    status, _out, err = run_script(SCRIPT, "--", "--post", @retired.id.to_s, "--as", "boss", "--apply")

    assert_equal(1, status)
    assert_match(/was not deleted by the merge/, err)
    assert_empty(@storage.deleted)
  end

  should "refuse a non-admin" do
    status, _out, err = run_script(SCRIPT, "--", "--post", @retired.id.to_s, "--as", "tunnel")
    assert_equal(2, status)
    assert_match(/not an admin/, err)
  end
end
