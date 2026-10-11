# frozen_string_literal: true

require "test_helper"

# script/fourier_original_characters.rb, run as a person runs it: the file
# itself, with argv. Its one write is the copyright tag `original` and its
# wiki page; everything else it prints is an inventory for the operator --
# the oc_ tags the 2026-09-19 rule made, and the tags already named for an
# existing creator -- and writes nothing.
class FourierOriginalCharactersScriptTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("script/fourier_original_characters.rb").to_s

  # [exit status, stdout, stderr]
  def run_script(*argv)
    status = nil
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

  setup do
    @admin = create(:admin_user, name: "boss")
    @tunnel = create(:builder_user, name: "tunnel")
    @post = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "oc_kayla ariah_oc pine_(saber) landscape") }
    FourierPostCreator.create!(post: @post, mxid: "@saber:41chan.net", recorded_by: @tunnel.id)
    Tag.find_by_name("oc_kayla").update!(category: TagCategory::CHARACTER, updater: @admin)
    CreatorGallery.create!(slug: "saber", matrix_id: "@saber:41chan.net")
    as(@admin) { create(:wiki_page, title: "pine_(saber)") }
  end

  should "refuse a missing or non-admin account, and an abbreviated --apply" do
    [%w[--as nobody], %w[--as tunnel], %w[--as boss --ap]].each do |argv|
      status, _out, err = run_script("--", *argv)
      assert_equal(2, status, argv.inspect)
      assert_match(/fix: /, err, argv.inspect)
    end
    assert_nil(Tag.find_by_name("original"))
  end

  should "dry-run by default: report the inventory, write nothing" do
    status, out, _err = run_script("--", "--as", "boss")

    assert_nil(status)
    assert_match(%r{\[1/\d+\] tag original: missing -> copyright}, out)
    assert_match(/oc_ tag oc_kayla: character, 1 post, posted by @saber:41chan\.net/, out)
    assert_match(/oc_ tag ariah_oc: general, 1 post, posted by @saber:41chan\.net/, out)
    assert_match(/named for creator saber: pine_\(saber\), 1 post, wiki page/, out)
    assert_match(/DRY RUN/, out)
    assert_nil(Tag.find_by_name("original"))
    assert_nil(WikiPage.find_by(title: "original"))
  end

  should "make original a copyright tag with a wiki page on --apply, and change nothing on a second run" do
    status, out, _err = run_script("--", "--as", "boss", "--apply")

    assert_nil(status, out)
    assert(Tag.find_by_name("original").copyright?)
    assert(WikiPage.find_by!(title: "original").body.present?)

    _status, out, _err = run_script("--", "--as", "boss", "--apply")
    assert_match(/tag original: already copyright/, out)
    assert_match(/wiki original: exists/, out)
    assert_equal(1, WikiPage.where(title: "original").count)
  end
end
