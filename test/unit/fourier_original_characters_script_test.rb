# frozen_string_literal: true

require "test_helper"

# script/fourier_original_characters.rb, run as a person runs it: the file
# itself, with argv. Without --oc-owner its one write is the copyright tag
# `original` and its wiki page, and everything else it prints is an
# inventory for the operator -- the tags in the four 2026-09-19 shapes, and
# the tags already named for an existing creator. With --oc-owner OWNER it
# also moves every old-shape tag onto <name>_(OWNER) (operator, 2026-10-11:
# "oc_name is my personal tag"): an alias, the target a character implying
# `original`, and OWNER's claim on it when OWNER has a creator gallery. One
# transaction: a dry run and a refused run write nothing.
class FourierOriginalCharactersScriptTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("script/fourier_original_characters.rb").to_s
  OLD_SHAPES = %w[oc_kayla kayla_oc character_oc_juno moss_character_oc ariah_oc].freeze

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
    CreatorPrefixes.reset!
    @admin = create(:admin_user, name: "boss")
    @tunnel = create(:builder_user, name: "tunnel")
    @post = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "oc_kayla ariah_oc pine_(saber) landscape") }
    @older = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "kayla_oc character_oc_juno moss_character_oc") }
    FourierPostCreator.create!(post: @post, mxid: "@saber:41chan.net", recorded_by: @tunnel.id)
    Tag.find_by_name("oc_kayla").update!(category: TagCategory::CHARACTER, updater: @admin)
    @gallery = CreatorGallery.create!(slug: "saber", matrix_id: "@saber:41chan.net")
    as(@admin) { create(:wiki_page, title: "pine_(saber)") }
  end

  should "refuse a missing or non-admin account, an abbreviated --apply, and an owner that is no Matrix name" do
    [%w[--as nobody], %w[--as tunnel], %w[--as boss --ap], %w[--as boss --oc-owner Saber], ["--as", "boss", "--oc-owner", ""]].each do |argv|
      status, _out, err = run_script("--", *argv)
      assert_equal(2, status, argv.inspect)
      assert_match(/fix: /, err, argv.inspect)
    end
    assert_nil(Tag.find_by_name("original"))
  end

  should "dry-run by default: report the inventory, all four old shapes included, and write nothing" do
    status, out, _err = run_script("--", "--as", "boss")

    assert_nil(status)
    assert_match(%r{\[1/\d+\] tag original: missing -> copyright}, out)
    assert_match(/oc_ tag oc_kayla: character, 1 post, posted by @saber:41chan\.net/, out)
    assert_match(/oc_ tag ariah_oc: general, 1 post, posted by @saber:41chan\.net/, out)
    assert_match(/oc_ tag kayla_oc: general, 1 post, posted by no recorded creator/, out)
    assert_match(/oc_ tag character_oc_juno: general, 1 post/, out)
    assert_match(/oc_ tag moss_character_oc: general, 1 post/, out)
    assert_match(/named for creator saber: pine_\(saber\), 1 post, wiki page/, out)
    assert_match(/DRY RUN/, out)
    assert_nil(Tag.find_by_name("original"))
    assert_nil(WikiPage.find_by(title: "original"))
  end

  # The regex finds candidates; the booru's own reading decides. A name that
  # already ends in a creator in brackets matches the old regex's oc_ prefix
  # but is not an old shape, so it is never listed or moved as one.
  should "not list a name that already ends in a creator in brackets as an old shape" do
    as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "oc_maple_(saber)") }

    _status, out, _err = run_script("--", "--as", "boss", "--oc-owner", "saber")

    assert_no_match(/oc_ tag oc_maple_\(saber\)/, out)
    assert_no_match(/alias oc_maple_\(saber\)/, out)
  end

  should "make original a copyright tag with a wiki page on --apply, and change nothing on a second run" do
    status, out, _err = run_script("--", "--as", "boss", "--apply")

    assert_nil(status, out)
    assert(Tag.find_by_name("original").copyright?)
    assert(WikiPage.find_by!(title: "original").body.present?)
    assert_equal(0, TagAlias.count, "no alias without --oc-owner")

    _status, out, _err = run_script("--", "--as", "boss", "--apply")
    assert_match(/tag original: already copyright/, out)
    assert_match(/wiki original: exists/, out)
    assert_equal(1, WikiPage.where(title: "original").count)
    # Not "every step is already done": five old-shape tags have not moved.
    assert_no_match(/every step is already done/, out)
    assert_match(/nothing written: 5 oc_ tags above have not moved; --oc-owner <localpart> moves them/, out)
  end

  should "plan, with --oc-owner, a move of every old-shape tag onto <name>_(owner), and write nothing on a dry run" do
    status, out, _err = run_script("--", "--as", "boss", "--oc-owner", "saber")

    assert_nil(status, out)
    assert_match(/alias oc_kayla -> kayla_\(saber\): 1 post moves/, out)
    assert_match(/alias kayla_oc -> kayla_\(saber\): 1 post moves/, out)
    assert_match(/alias character_oc_juno -> juno_\(saber\)/, out)
    assert_match(/alias moss_character_oc -> moss_\(saber\)/, out)
    assert_match(/alias ariah_oc -> ariah_\(saber\)/, out)
    assert_match(/kayla_\(saber\) implies original/, out)
    assert_match(/claim kayla_\(saber\) for @saber: approved by boss/, out)
    assert_match(/DRY RUN/, out)
    assert_equal(0, TagAlias.count)
    assert_equal(0, TagImplication.count)
    assert_equal(0, CharacterClaim.count)
    assert_nil(Tag.find_by_name("kayla_(saber)"))
    assert_nil(Tag.find_by_name("original"))
    assert_includes(@post.reload.tag_array, "oc_kayla")
  end

  should "on --apply --oc-owner, alias every old shape, file each target as a character implying original, approve the owner's claim, and skip everything on a second run" do
    status, out, _err = run_script("--", "--as", "boss", "--oc-owner", "saber", "--apply")
    assert_nil(status, out)
    assert_no_match(/REFUSED/, out)

    targets = { "oc_kayla" => "kayla_(saber)", "kayla_oc" => "kayla_(saber)", "character_oc_juno" => "juno_(saber)",
                "moss_character_oc" => "moss_(saber)", "ariah_oc" => "ariah_(saber)" }
    targets.each do |legacy, target|
      assert(TagAlias.active.exists?(antecedent_name: legacy, consequent_name: target), "#{legacy} -> #{target}")
    end
    assert_equal(%w[ariah_(saber) kayla_(saber) landscape original pine_(saber)], @post.reload.tag_array.sort)
    assert_equal(%w[juno_(saber) kayla_(saber) moss_(saber) original], @older.reload.tag_array.sort)
    assert(Tag.find_by_name("original").copyright?, "original stays copyright after its first implication")

    targets.values.uniq.each do |target|
      assert(Tag.find_by_name(target).character?, target)
      assert(TagImplication.active.exists?(antecedent_name: target, consequent_name: "original"), target)
      claim = CharacterClaim.approved.find_by!(tag_name: target)
      assert_equal([@gallery.id, @admin.id], [claim.creator_gallery_id, claim.approver_id], target)
    end
    assert_equal(4, ModAction.where(category: "character_claim_approve", creator: @admin).count)

    counts = -> { [TagAlias.count, TagImplication.count, CharacterClaim.count, ModAction.count, Tag.count] }
    before = counts.call
    status, out, _err = run_script("--", "--as", "boss", "--oc-owner", "saber", "--apply")

    assert_nil(status, out)
    assert_equal(before, counts.call)
    assert_match(/alias oc_kayla -> kayla_\(saber\): already in place/, out)
    assert_match(/kayla_\(saber\): already a character/, out)
    assert_match(/kayla_\(saber\) already implies original/, out)
    assert_match(/claim kayla_\(saber\) for @saber: already stands/, out)
    assert_match(/nothing to write/, out)
  end

  should "alias without a claim when the owner has no creator gallery" do
    status, out, _err = run_script("--", "--as", "boss", "--oc-owner", "bob", "--apply")

    assert_nil(status, out)
    assert(TagAlias.active.exists?(antecedent_name: "oc_kayla", consequent_name: "kayla_(bob)"))
    assert_match(/no creator gallery bob: no claim filed/, out)
    assert_equal(0, CharacterClaim.count)
  end

  should "refuse a target the claim rule refuses, and write nothing at all" do
    status, out, err = run_script("--", "--as", "boss", "--oc-owner", "cosplay", "--apply")

    assert_equal(1, status, out)
    assert_match(/REFUSED oc_kayla -> kayla_\(cosplay\): .*a meaning of its own/, out)
    assert_match(/wrote nothing/, out)
    assert_match(/fix: /, err)
    assert_equal(0, TagAlias.count)
    assert_nil(Tag.find_by_name("original"))
    assert_nil(Tag.find_by_name("ariah_(cosplay)"))
  end

  should "refuse an old-shape tag already aliased somewhere else, and write nothing at all" do
    as(@admin) { TagAlias.approve!(antecedent_name: "oc_kayla", consequent_name: "kayla", approver: @admin) }

    status, out, _err = run_script("--", "--as", "boss", "--oc-owner", "saber", "--apply")

    assert_equal(1, status, out)
    assert_match(/REFUSED oc_kayla -> kayla_\(saber\): oc_kayla is already aliased to kayla/, out)
    assert_equal(1, TagAlias.count)
    assert_nil(Tag.find_by_name("ariah_(saber)"))
    assert_nil(Tag.find_by_name("original"))
  end
end
