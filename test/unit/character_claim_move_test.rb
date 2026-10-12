# frozen_string_literal: true

require "test_helper"

# OWNERSHIP ON MOVE (operator, 2026-10-12: "Many of these characters belong to
# other creators, I'll just be the first one to post them" -- the poster is not
# the creator -- and "at which point selphdestruct should be immediately
# assigned ownership"). Whenever a tag in one of the 2026-09-19 shapes
# (oc_<name>, character_oc_<name>, <name>_oc, <name>_character_oc) is moved
# onto <base>_(<q>) -- by an alias or a rename, both of which run through
# TagMover -- the creator named by <q> gets an APPROVED claim on the target at
# once, decided by the approver of the move. Never the poster, never the mover.
# With no gallery named <q> yet, the claim is HELD for that name and approved
# the moment such a gallery is made.
class CharacterClaimMoveTest < ActiveSupport::TestCase
  include BulkUpdateRequestTestHelper

  setup do
    CreatorPrefixes.reset!
    @boss = create(:admin_user, name: "boss")
    @poster = create(:user, name: "saber")
    @post = as(@boss) { create(:post, tag_string: "oc_kayla landscape") }
    FourierPostCreator.create!(post: @post, mxid: "@saber:41chan.net", recorded_by: @boss.id)
    # The poster has a gallery of their own: it must never be the one that gets the claim.
    @poster_gallery = CreatorGallery.create!(slug: "saber", matrix_id: "@saber:41chan.net", user: @poster)
  end

  def alias!(from, to, approver: @boss)
    as(approver) { TagAlias.approve!(antecedent_name: from, consequent_name: to, approver: approver) }
  end

  context "a creator with a gallery" do
    setup do
      @selph = create(:user, name: "selph")
      @gallery = CreatorGallery.create!(slug: "selphdestruct", matrix_id: "@selphdestruct:41chan.net", user: @selph)
    end

    should "get an approved claim the moment an alias moves a legacy tag onto their name, decided by the alias's approver" do
      alias!("oc_kayla", "kayla_(selphdestruct)")

      claim = CharacterClaim.approved.find_by!(tag_name: "kayla_(selphdestruct)")
      assert_equal([@gallery.id, @boss.id], [claim.creator_gallery_id, claim.approver_id])
      assert_equal(0, CharacterClaim.where(creator_gallery: @poster_gallery).count, "never the poster's")
      assert(Tag.find_by_name("kayla_(selphdestruct)").character?)
      assert(TagImplication.active.exists?(antecedent_name: "kayla_(selphdestruct)", consequent_name: "original"))
      action = ModAction.where(category: "character_claim_approve").last
      assert_equal(@boss.id, action.creator_id)
      assert_match(/@selphdestruct's claim on original character kayla_\(selphdestruct\)/, action.description)
      assert_match(/oc_kayla/, action.description, "the log says which move decided it")
      assert_includes(@post.reload.tag_array, "kayla_(selphdestruct)")
      assert_equal(["kayla_(selphdestruct)"], CharacterClaim.standing_on(["kayla_(selphdestruct)"]).map(&:tag_name))
    end

    should "get it from a rename request too, decided by the request's approver" do
      create_bur!("rename oc_kayla -> kayla_(selphdestruct)", @boss)

      claim = CharacterClaim.approved.find_by!(tag_name: "kayla_(selphdestruct)")
      assert_equal([@gallery.id, @boss.id], [claim.creator_gallery_id, claim.approver_id])
      # A rename leaves no redirect, but a legacy name must keep one: old
      # images' prompts still say oc_kayla, and an unredirected oc_kayla would
      # be declared as itself again, splitting the character in two.
      assert(TagAlias.active.exists?(antecedent_name: "oc_kayla", consequent_name: "kayla_(selphdestruct)"),
             "a rename of a legacy tag leaves the alias an alias request would")
    end

    should "get it from an alias request, every shape counting" do
      as(@boss) { create(:post, tag_string: "moss_character_oc") }
      create_bur!("alias moss_character_oc -> moss_(selphdestruct)", @boss)

      assert(CharacterClaim.approved.exists?(tag_name: "moss_(selphdestruct)", creator_gallery: @gallery, approver: @boss))
    end

    should "approve the creator's own pending claim rather than file a second" do
      create(:tag, name: "kayla_(selphdestruct)", category: Tag.categories.character, post_count: 3)
      pending = CharacterClaim.create!(creator_gallery: @gallery, tag_name: "kayla_(selphdestruct)")

      alias!("oc_kayla", "kayla_(selphdestruct)")

      assert_equal([pending.id], CharacterClaim.approved.where(tag_name: "kayla_(selphdestruct)").pluck(:id))
      assert_equal(1, CharacterClaim.where(tag_name: "kayla_(selphdestruct)").count)
    end

    should "leave a claim that already stands as it is when a second shape moves onto the same tag" do
      as(@boss) { create(:post, tag_string: "kayla_oc") }
      alias!("oc_kayla", "kayla_(selphdestruct)")
      alias!("kayla_oc", "kayla_(selphdestruct)")

      assert_equal(1, CharacterClaim.where(tag_name: "kayla_(selphdestruct)").count)
      assert_equal(1, ModAction.where(category: "character_claim_approve").count)
    end

    should "confer nothing when the moved tag is not a legacy shape" do
      as(@boss) { create(:post, tag_string: "kayla") }
      alias!("kayla", "kayla_(selphdestruct)")

      assert_equal(0, CharacterClaim.count)
    end
  end

  context "a creator with no gallery yet" do
    should "be held a claim for their name, approved the moment their gallery is made" do
      alias!("oc_kayla", "kayla_(selphdestruct)")

      held = CharacterClaim.find_by!(tag_name: "kayla_(selphdestruct)")
      assert_equal([CharacterClaim::HELD, "selphdestruct", nil, @boss.id], [held.status, held.creator_slug, held.creator_gallery_id, held.approver_id])
      assert_empty(CharacterClaim.standing_on(["kayla_(selphdestruct)"]), "held is not owned")
      assert(Tag.find_by_name("kayla_(selphdestruct)").character?, "the target is a character from the move on")
      assert(TagImplication.active.exists?(antecedent_name: "kayla_(selphdestruct)", consequent_name: "original"))
      assert_equal(0, CharacterClaim.where(creator_gallery: @poster_gallery).count, "never the poster's")

      gallery = CreatorGallery.create!(slug: "selphdestruct", matrix_id: "@selphdestruct:41chan.net")

      held.reload
      assert_equal([CharacterClaim::APPROVED, gallery.id, @boss.id], [held.status, held.creator_gallery_id, held.approver_id])
      assert_equal(["kayla_(selphdestruct)"], CharacterClaim.standing_on(["kayla_(selphdestruct)"]).map(&:tag_name))
      action = ModAction.where(category: "character_claim_approve").last
      assert_equal(@boss.id, action.creator_id)
      assert_match(/held for @selphdestruct/, action.description)
    end

    should "hold one claim per tag however many shapes move onto it" do
      as(@boss) { create(:post, tag_string: "kayla_oc") }
      alias!("oc_kayla", "kayla_(selphdestruct)")
      alias!("kayla_oc", "kayla_(selphdestruct)")

      assert_equal(1, CharacterClaim.where(tag_name: "kayla_(selphdestruct)").count)
    end

    should "leave a held claim pending for an admin, saying why, when it cannot be approved once the gallery appears" do
      alias!("oc_kayla", "kayla_(selphdestruct)")
      held = CharacterClaim.find_by!(tag_name: "kayla_(selphdestruct)")
      create(:tag_alias, antecedent_name: "kayla_(selphdestruct)", consequent_name: "kayla_marie")
      Rails.logger.stubs(:warn)
      Rails.logger.expects(:warn).with(regexp_matches(/kayla_\(selphdestruct\).*aliased to kayla_marie/))

      gallery = CreatorGallery.create!(slug: "selphdestruct", matrix_id: "@selphdestruct:41chan.net")

      assert(gallery.persisted?, "the gallery is made whatever the claim does")
      held.reload
      assert_equal([CharacterClaim::PENDING, gallery.id], [held.status, held.creator_gallery_id])
      assert_match(/could not be approved automatically.*aliased to kayla_marie/, held.note)
    end
  end

  context "a target the claim rule refuses" do
    should "refuse the alias request by name, before anything moves" do
      bur = build(:bulk_update_request, script: "alias oc_kayla -> kayla_(cosplay)")

      assert_not(bur.valid?)
      assert_match(/kayla_\(cosplay\).*a meaning of its own/, bur.errors.full_messages.join)
    end

    should "refuse a rename request onto a creator prefix by name" do
      bur = build(:bulk_update_request, script: "rename oc_kayla -> 41chan_kayla_(selphdestruct)")

      assert_not(bur.valid?)
      assert_match(/41chan_ marks creator tags/, bur.errors.full_messages.join)
    end

    # hilda_(pokemon) names a series, not a creator: a hold for "@pokemon"
    # would make a canon character an original one, owned by whoever later
    # registers that Matrix name.
    should "refuse a move onto a series' character: <q> a copyright tag with no creator page of that name" do
      create(:tag, name: "pokemon", category: Tag.categories.copyright)
      create(:tag, name: "hilda_(pokemon)", category: Tag.categories.character)

      bur = build(:bulk_update_request, script: "alias oc_kayla -> hilda_(pokemon)")
      assert_not(bur.valid?)
      assert_match(/pokemon is a copyright tag.*mass update oc_kayla -> hilda_\(pokemon\)/, bur.errors.full_messages.join)

      assert_raises(CharacterClaim::MoveRefused) { alias!("oc_kayla", "hilda_(pokemon)") }
      assert_equal(0, CharacterClaim.count)
      assert_not(Tag.find_by_name("hilda_(pokemon)").implies?("original"))
    end

    should "still give <q> the character when a creator page of that name exists, whatever else is named so" do
      create(:tag, name: "selphdestruct", category: Tag.categories.copyright)
      gallery = CreatorGallery.create!(slug: "selphdestruct", matrix_id: "@selphdestruct:41chan.net")

      alias!("oc_kayla", "kayla_(selphdestruct)")

      assert(CharacterClaim.approved.exists?(tag_name: "kayla_(selphdestruct)", creator_gallery: gallery))
    end

    should "refuse the move itself, loudly and before anything moves, when it is reached anyway" do
      error = assert_raises(CharacterClaim::MoveRefused) { alias!("oc_kayla", "kayla_(cosplay)") }

      assert_match(/oc_kayla -> kayla_\(cosplay\).*a meaning of its own/, error.message)
      assert_includes(@post.reload.tag_array, "oc_kayla")
      assert_equal(0, CharacterClaim.count)
    end
  end
end
