# frozen_string_literal: true

require "test_helper"

# script/fourier_original_characters.rb, run as a person runs it: the file
# itself, with argv. Its one write without a map is the copyright tag
# `original` and its wiki page. Everything else it prints is an inventory for
# the operator: every tag in the four 2026-09-19 shapes with its post count and
# recorded posters, a ready-to-fill template of "OLD <creator>" lines for the
# ones not yet mapped, and the tags already named for an existing creator.
#
# The owners come ONLY from the operator (2026-10-12: "Many of these
# characters belong to other creators, I'll just be the first one to post
# them"): --map OLD=CREATOR and --map-file PATH ("-" for stdin). --apply moves
# only the mapped tags -- an alias onto <base>_(CREATOR), the target a
# character implying `original`, and CREATOR's ownership (held until their
# gallery exists) -- and leaves every unmapped one untouched. Any refused map
# line refuses the run. One transaction: a dry run and a refused run write
# nothing.
class FourierOriginalCharactersScriptTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("script/fourier_original_characters.rb").to_s

  # [exit status, stdout, stderr]
  def run_script(*argv, stdin: nil)
    status = nil
    saved = ARGV.dup
    saved_stdin = $stdin
    ARGV.replace(argv)
    $stdin = StringIO.new(stdin) if stdin
    out, err = capture_io do
      load SCRIPT
    rescue SystemExit => e
      status = e.status
    end
    [status, out, err]
  ensure
    ARGV.replace(saved)
    $stdin = saved_stdin
  end

  setup do
    CreatorPrefixes.reset!
    @admin = create(:admin_user, name: "boss")
    @tunnel = create(:builder_user, name: "tunnel")
    @post = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "oc_kayla ariah_oc pine_(selph) landscape") }
    @older = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "kayla_oc character_oc_juno moss_character_oc") }
    FourierPostCreator.create!(post: @post, mxid: "@saber:41chan.net", recorded_by: @tunnel.id)
    Tag.find_by_name("oc_kayla").update!(category: TagCategory::CHARACTER, updater: @admin)
    # The POSTER has a gallery. Nothing here may ever give it a claim.
    @poster_gallery = CreatorGallery.create!(slug: "saber", matrix_id: "@saber:41chan.net")
    @gallery = CreatorGallery.create!(slug: "selph", matrix_id: "@selph:41chan.net")
    as(@admin) { create(:wiki_page, title: "pine_(selph)") }
  end

  should "refuse a missing or non-admin account, an abbreviated --apply, and the retired --oc-owner" do
    [%w[--as nobody], %w[--as tunnel], %w[--as boss --ap], %w[--as boss --oc-owner saber]].each do |argv|
      status, _out, err = run_script("--", *argv)
      assert_equal(2, status, argv.inspect)
      assert_match(/fix: /, err, argv.inspect)
    end
    assert_nil(Tag.find_by_name("original"))
  end

  should "dry-run by default: list every legacy tag with posts and posters, print a template for the unmapped ones, write nothing" do
    status, out, _err = run_script("--", "--as", "boss")

    assert_nil(status)
    assert_match(%r{\[1/\d+\] tag original: missing -> copyright}, out)
    assert_match(/oc_ tag oc_kayla: character, 1 post, posted by @saber:41chan\.net, not mapped/, out)
    assert_match(/oc_ tag ariah_oc: general, 1 post, posted by @saber:41chan\.net, not mapped/, out)
    assert_match(/oc_ tag kayla_oc: general, 1 post, posted by no recorded creator, not mapped/, out)
    assert_match(/oc_ tag character_oc_juno: general, 1 post/, out)
    assert_match(/oc_ tag moss_character_oc: general, 1 post/, out)
    assert_match(/named for creator selph: pine_\(selph\), 1 post, wiki page/, out)
    template = out[/^--- map template.*?^--- end of template ---$/m]
    assert(template, out)
    %w[ariah_oc character_oc_juno kayla_oc moss_character_oc oc_kayla].each do |name|
      assert_match(/^#{Regexp.escape(name)} <creator>$/, template, name)
    end
    assert_match(/DRY RUN/, out)
    assert_nil(Tag.find_by_name("original"))
    assert_nil(WikiPage.find_by(title: "original"))
  end

  # The regex finds candidates; the booru's own reading decides. A name that
  # already ends in a creator in brackets matches the old regex's oc_ prefix
  # but is not an old shape, so it is never listed, templated or mappable.
  should "not list a name that already ends in a creator in brackets as an old shape, and refuse a map line naming it" do
    as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "oc_maple_(selph)") }

    _status, out, _err = run_script("--", "--as", "boss")
    assert_no_match(/oc_maple_\(selph\)/, out[/^--- map template.*?^--- end of template ---$/m])
    assert_no_match(/oc_ tag oc_maple_\(selph\)/, out)

    status, out, _err = run_script("--", "--as", "boss", "--map", "oc_maple_(selph)=selph", "--apply")
    assert_equal(1, status, out)
    assert_match(/REFUSED map oc_maple_\(selph\)=selph: oc_maple_\(selph\) is not a legacy original-character tag/, out)
  end

  should "make original a copyright tag with a wiki page on --apply without a map, move nothing, and change nothing on a second run" do
    status, out, _err = run_script("--", "--as", "boss", "--apply")

    assert_nil(status, out)
    assert(Tag.find_by_name("original").copyright?)
    assert(WikiPage.find_by!(title: "original").body.present?)
    assert_equal(0, TagAlias.count, "nothing is moved without a map")

    _status, out, _err = run_script("--", "--as", "boss", "--apply")
    assert_match(/tag original: already copyright/, out)
    assert_match(/wiki original: exists/, out)
    assert_equal(1, WikiPage.where(title: "original").count)
    assert_match(/5 legacy tags not mapped, left as they are/, out)
  end

  should "plan only the mapped tags on a dry run with a map, list the rest as unmapped, and write nothing" do
    status, out, _err = run_script("--", "--as", "boss", "--map", "oc_kayla=selph", "--map", "kayla_oc=selph")

    assert_nil(status, out)
    assert_match(/alias oc_kayla -> kayla_\(selph\): 1 post moves/, out)
    assert_match(/alias kayla_oc -> kayla_\(selph\): 1 post moves/, out)
    assert_match(/kayla_\(selph\) implies original/, out)
    assert_match(/owner of kayla_\(selph\): @selph, approved by boss/, out)
    assert_match(/oc_ tag ariah_oc: .*not mapped/, out)
    assert_no_match(/alias ariah_oc/, out)
    template = out[/^--- map template.*?^--- end of template ---$/m]
    assert_match(/^ariah_oc <creator>$/, template)
    assert_no_match(/^oc_kayla /, template, "a mapped tag is not in the template")
    assert_match(/DRY RUN/, out)
    assert_equal(0, TagAlias.count)
    assert_equal(0, TagImplication.count)
    assert_equal(0, CharacterClaim.count)
    assert_nil(Tag.find_by_name("kayla_(selph)"))
    assert_nil(Tag.find_by_name("original"))
    assert_includes(@post.reload.tag_array, "oc_kayla")
  end

  should "on --apply, move only the mapped tags: alias, character implying original, the named creator's ownership -- and skip everything on a rerun" do
    status, out, _err = run_script("--", "--as", "boss", "--map", "oc_kayla=selph", "--map", "kayla_oc=selph", "--apply")
    assert_nil(status, out)
    assert_no_match(/REFUSED/, out)

    assert(TagAlias.active.exists?(antecedent_name: "oc_kayla", consequent_name: "kayla_(selph)"))
    assert(TagAlias.active.exists?(antecedent_name: "kayla_oc", consequent_name: "kayla_(selph)"))
    assert_equal(%w[ariah_oc kayla_(selph) landscape original pine_(selph)], @post.reload.tag_array.sort)
    assert_equal(%w[character_oc_juno kayla_(selph) moss_character_oc original], @older.reload.tag_array.sort)
    assert(Tag.find_by_name("original").copyright?, "original stays copyright after its first implication")
    assert(Tag.find_by_name("kayla_(selph)").character?)
    assert(TagImplication.active.exists?(antecedent_name: "kayla_(selph)", consequent_name: "original"))
    claim = CharacterClaim.approved.find_by!(tag_name: "kayla_(selph)")
    assert_equal([@gallery.id, @admin.id], [claim.creator_gallery_id, claim.approver_id])
    assert_equal(0, CharacterClaim.where(creator_gallery: @poster_gallery).count, "never the poster's")
    assert_equal(1, ModAction.where(category: "character_claim_approve", creator: @admin).count)
    assert_match(/3 legacy tags not mapped, left as they are: ariah_oc, character_oc_juno, moss_character_oc/, out)

    counts = -> { [TagAlias.count, TagImplication.count, CharacterClaim.count, ModAction.count, Tag.count] }
    before = counts.call
    status, out, _err = run_script("--", "--as", "boss", "--map", "oc_kayla=selph", "--map", "kayla_oc=selph", "--apply")

    assert_nil(status, out)
    assert_equal(before, counts.call)
    assert_match(/alias oc_kayla -> kayla_\(selph\): already in place/, out)
    assert_match(/kayla_\(selph\): already a character/, out)
    assert_match(/kayla_\(selph\) already implies original/, out)
    assert_match(/owner of kayla_\(selph\): @selph, already stands/, out)
    assert_match(/nothing to write/, out)
  end

  should "hold ownership for a creator with no gallery yet, and approve it once their gallery is made" do
    status, out, _err = run_script("--", "--as", "boss", "--map", "ariah_oc=newbie", "--apply")

    assert_nil(status, out)
    assert(TagAlias.active.exists?(antecedent_name: "ariah_oc", consequent_name: "ariah_(newbie)"))
    assert_match(/owner of ariah_\(newbie\): held for @newbie, approved by boss the moment a creator gallery named newbie exists/, out)
    held = CharacterClaim.find_by!(tag_name: "ariah_(newbie)")
    assert_equal(CharacterClaim::HELD, held.status)

    gallery = CreatorGallery.create!(slug: "newbie", matrix_id: "@newbie:41chan.net")
    assert_equal([CharacterClaim::APPROVED, gallery.id, @admin.id], held.reload.slice(:status, :creator_gallery_id, :approver_id).values)

    _status, out, _err = run_script("--", "--as", "boss", "--map", "ariah_oc=newbie", "--apply")
    assert_match(/owner of ariah_\(newbie\): @newbie, already stands/, out)
    assert_match(/nothing to write/, out)
  end

  should "read the map from a file and from stdin, ignoring comments and blank lines" do
    file = Tempfile.new("oc-map")
    file.write("# who drew whom\n\noc_kayla selph\n  # indented comment\nkayla_oc   selph\n")
    file.close
    status, out, _err = run_script("--", "--as", "boss", "--map-file", file.path, "--apply")
    assert_nil(status, out)
    assert(TagAlias.active.exists?(antecedent_name: "kayla_oc", consequent_name: "kayla_(selph)"))

    status, out, _err = run_script("--", "--as", "boss", "--map-file", "-", "--apply", stdin: "ariah_oc newbie\n")
    assert_nil(status, out)
    assert(TagAlias.active.exists?(antecedent_name: "ariah_oc", consequent_name: "ariah_(newbie)"))
  ensure
    file&.unlink
  end

  should "refuse, by name and writing nothing at all, a malformed line, a non-legacy tag, an invalid creator, a conflicting pair, and an unfilled template line" do
    bad = {
      "oc_kayla" => /line 1 "oc_kayla" is not "OLD CREATOR"/,
      "oc_kayla selph extra" => /line 1 "oc_kayla selph extra" is not "OLD CREATOR"/,
      "landscape selph" => /landscape is not a legacy original-character tag/,
      "oc_nobody selph" => /oc_nobody is not a legacy original-character tag/,
      "oc_kayla Selph!" => /Selph! is not a creator's name/,
      "oc_kayla <creator>" => /<creator> is not a creator's name/,
      "oc_kayla selph\noc_kayla bob" => /oc_kayla is mapped twice: to selph and to bob/,
    }
    bad.each do |map, why|
      status, out, err = run_script("--", "--as", "boss", "--map-file", "-", "--apply", stdin: "#{map}\nariah_oc selph\n")

      assert_equal(1, status, "#{map.inspect}: #{out}")
      assert_match(why, out, map.inspect)
      assert_match(/wrote nothing/, out, map.inspect)
      assert_match(/fix: /, err, map.inspect)
    end
    assert_equal(0, TagAlias.count)
    assert_nil(Tag.find_by_name("original"))
    assert_nil(Tag.find_by_name("ariah_(selph)"))

    status, out, _err = run_script("--", "--as", "boss", "--map", "oc_kayla", "--apply")
    assert_equal(1, status, out)
    assert_match(/--map "oc_kayla" is not OLD=CREATOR/, out)
  end

  should "refuse a target the claim rule refuses, and write nothing at all" do
    status, out, err = run_script("--", "--as", "boss", "--map", "oc_kayla=cosplay", "--map", "ariah_oc=selph", "--apply")

    assert_equal(1, status, out)
    assert_match(/REFUSED oc_kayla -> kayla_\(cosplay\): .*a meaning of its own/, out)
    assert_match(/wrote nothing/, out)
    assert_match(/fix: /, err)
    assert_equal(0, TagAlias.count)
    assert_nil(Tag.find_by_name("original"))
    assert_nil(Tag.find_by_name("ariah_(selph)"))
  end

  should "refuse a mapped tag already aliased somewhere else, and write nothing at all" do
    as(@admin) { TagAlias.approve!(antecedent_name: "oc_kayla", consequent_name: "kayla", approver: @admin) }

    status, out, _err = run_script("--", "--as", "boss", "--map", "oc_kayla=selph", "--map", "ariah_oc=selph", "--apply")

    assert_equal(1, status, out)
    assert_match(/REFUSED oc_kayla -> kayla_\(selph\): oc_kayla is already aliased to kayla/, out)
    assert_equal(1, TagAlias.count)
    assert_nil(Tag.find_by_name("ariah_(selph)"))
    assert_nil(Tag.find_by_name("original"))
  end
end
