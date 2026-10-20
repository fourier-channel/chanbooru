require "test_helper"

# Who put each occurrence of a tag on a post's public list (BUR review
# 2026-10-19): a posting bot's add is a leak of the creator's prompt when the
# tag has a private row; anyone else's add is that person's own choice. Judged
# per occurrence from the post's versions, never from who touched the post
# last (memory who-touched-it-is-not-who-chose-it, drafted 2026-10-19).
class FourierPrivateTagLineageTest < ActiveSupport::TestCase
  SECRET = "secret_prompt_tag"

  def lineage_after(version)
    FourierPrivateTagLineage.after(version)
  end

  def versions
    @post.versions.order(:version).to_a
  end

  setup do
    @tunnel = create(:builder_user, name: "tunnel")
    @member = create(:user)
    @admin = create(:admin_user)
    as(@tunnel) { @post = create(:post, uploader: @tunnel, tag_string: "landscape #{SECRET}") }
  end

  should "start a bot lineage on a posting bot's add" do
    assert_equal({ "landscape" => :bot, SECRET => :bot }, lineage_after(versions.last))
  end

  should "start a public lineage on a person's add, and end any lineage on a removal" do
    as(@member) { @post.update!(tag_string: "landscape") }
    removed = versions.last
    as(@admin) { @post.update!(tag_string: "landscape #{SECRET}") }

    assert_equal({ "landscape" => :bot }, lineage_after(removed))
    assert_equal({ "landscape" => :bot, SECRET => :public }, lineage_after(versions.last))
    assert_equal({ "landscape" => :bot, SECRET => :bot }, lineage_after(versions.first), "each version answers for itself")
  end

  should "carry the antecedent's lineage through an alias move" do
    as(@member) { @post.update!(tag_string: "landscape #{SECRET} sky") }
    TagAlias.approve!(antecedent_name: SECRET, consequent_name: "moved_secret", approver: @admin)
    TagAlias.approve!(antecedent_name: "sky", consequent_name: "blue_sky", approver: @admin)

    assert_equal(%w[blue_sky landscape moved_secret], @post.reload.tag_array, "fixture: the posts moved")
    assert_equal({ "landscape" => :bot, "moved_secret" => :bot, "blue_sky" => :public }, lineage_after(versions.last))
  end

  should "not carry a lineage through a bulk update that is not a move" do
    as(User.system) { @post.update!(tag_string: "landscape renamed_by_hand") }

    assert_equal({ "landscape" => :bot, "renamed_by_hand" => :public }, lineage_after(versions.last))
  end

  should "call a tag unknown when the history does not begin at the post's first version" do
    versions.first.update_columns(version: 2) # rubocop:disable Rails/SkipsModelValidations

    assert_equal({ "landscape" => :unknown, SECRET => :unknown }, lineage_after(versions.last))
  end

  # post_versions.updater_id is nullable: a post saved outside a request and
  # outside CurrentUser.scoped is versioned with no updater. Nobody can be
  # named for that add, so it is not a person's own choice -- except a label,
  # which is never a leak whoever added it.
  should "call an add unknown when its version has no updater on record, and refuse to restore it" do
    as(@tunnel) { @post = create(:post, uploader: @tunnel, tag_string: "landscape no_train #{SECRET}") }
    FourierTagSource.record_partition!(@post, { creator: [SECRET], auto: %w[landscape] }, @tunnel)
    first = versions.first
    first.update_columns(updater_id: nil) # rubocop:disable Rails/SkipsModelValidations
    assert_equal({ "landscape" => :unknown, "no_train" => :public, SECRET => :unknown }, lineage_after(first))

    first.update_columns(updater_id: User.maximum(:id) + 1000) # rubocop:disable Rails/SkipsModelValidations
    assert_equal({ "landscape" => :unknown, "no_train" => :public, SECRET => :unknown }, lineage_after(first), "an updater with no User row is no one either")

    as(@member) { @post.update!(tag_string: "landscape no_train") }
    assert_raises(FourierPrivateTagLineage::RestoreRefused) { as(create(:user)) { @post.revert_to!(first) } }
    assert_equal(%w[landscape no_train], @post.reload.tag_array)
  end

  # A move is TagMover's, run as the system account. A person's edit that
  # swaps one name for another is that person's add, even where an alias row
  # (of any status) names the pair.
  should "not carry a lineage through a person's swap that an alias row happens to name" do
    create(:tag_alias, antecedent_name: SECRET, consequent_name: "swapped_by_hand", status: "deleted", creator: @admin)
    as(@member) { @post.update!(tag_string: "landscape swapped_by_hand") }

    assert_equal(%w[landscape swapped_by_hand], @post.reload.tag_array, "fixture: the deleted alias did not apply")
    assert_equal({ "landscape" => :bot, "swapped_by_hand" => :public }, lineage_after(versions.last))
  end

  # fourier-tunnel image-plan.js publicTagsFor: "ai-generated" when the strip
  # took a generator's own signal, "no_train" on every Discord post. Sent on
  # purpose, whatever the prompt also says, so never a leak of it.
  should "call a label the posting bot publishes on purpose public, though a prompt names it too" do
    as(@tunnel) { @post = create(:post, uploader: @tunnel, tag_string: "landscape ai-generated no_train") }

    assert_equal({ "landscape" => :bot, "ai-generated" => :public, "no_train" => :public }, lineage_after(versions.last))
  end

  should "let anyone put back a label the posting bot publishes on purpose" do
    as(@tunnel) { @labelled = create(:post, uploader: @tunnel, tag_string: "landscape ai-generated") }
    FourierTagSource.record_partition!(@labelled, { creator: ["ai-generated"], auto: %w[landscape] }, @tunnel)
    as(@member) { @labelled.update!(tag_string: "landscape") }
    first = @labelled.versions.order(:version).first

    as(create(:user)) { @labelled.revert_to!(first) }
    assert_equal %w[ai-generated landscape], @labelled.reload.tag_array
  end

  should "carry the lineage through a rename, which leaves no alias row" do
    create_bur!("rename #{SECRET} -> renamed_secret", @admin)

    assert_equal(%w[landscape renamed_secret], @post.reload.tag_array, "fixture: the posts moved")
    assert_not TagAlias.exists?(antecedent_name: SECRET), "fixture: a rename is not an alias"
    assert_equal({ "landscape" => :bot, "renamed_secret" => :bot }, lineage_after(versions.last))
  end

  should "carry the lineage through the *_(cosplay) tag an alias moves along with its character" do
    as(@tunnel) { @post = create(:post, uploader: @tunnel, tag_string: "landscape leaked_(cosplay)") }
    TagAlias.approve!(antecedent_name: "leaked", consequent_name: "moved", approver: @admin)

    assert_equal(%w[cosplay landscape moved moved_(cosplay)], @post.reload.tag_array, "fixture: the cosplay tag moved too")
    assert_not TagAlias.exists?(antecedent_name: "leaked_(cosplay)"), "fixture: TagMover leaves no alias for the cosplay tag"
    assert_equal({ "cosplay" => :bot, "landscape" => :bot, "moved" => :bot, "moved_(cosplay)" => :bot }, lineage_after(versions.last))
  end

  # History redaction (PostVersion.private_names_withheld) judges a private
  # row's tag under every name it went by before, as its row moved with it:
  # through any number of moves, of any status, and never forward -- each
  # earlier name with the time the move from it ran, since an occurrence
  # begun after that is the name used again, not the row's.
  should "name every earlier name a tag went by, through more than one move, with when it moved" do
    first = create(:tag_alias, antecedent_name: "first_name", consequent_name: "second_name", status: "deleted", creator: @admin)
    second = create(:tag_alias, antecedent_name: "second_name", consequent_name: "third_name", status: "deleted", creator: @admin)
    create(:tag_alias, antecedent_name: "third_name", consequent_name: "later_name", status: "deleted", creator: @admin)
    pairs = FourierPrivateTagLineage.linked_moves(["third_name"])

    assert_equal([%w[first_name second_name], %w[second_name third_name], %w[third_name later_name]],
                 pairs.map { |from, to, _| [from, to] }.select { |pair| pair.none? { |name| name.end_with?(")") } }.sort)
    assert_equal({ "first_name" => first.reload.updated_at, "second_name" => second.reload.updated_at }, FourierPrivateTagLineage.earlier_names(["third_name"], pairs))
    assert_equal({ "first_name" => first.updated_at }, FourierPrivateTagLineage.earlier_names(["second_name"], pairs))
  end
end
