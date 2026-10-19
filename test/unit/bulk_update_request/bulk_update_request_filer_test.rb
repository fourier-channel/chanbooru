require "test_helper"

# Fork: a posting bot files a request for a person (Neru-chan, for a Voice
# user in a Matrix room) and itself sees every quarantined name. What it
# files may name only the tags a signed-out visitor may (operator,
# 2026-10-19): the bot's sight must not stand in for the person's. The
# refusal names no tag; the lines it was refused for carry no tag in their
# reason.
class BulkUpdateRequestFilerTest < ActiveSupport::TestCase
  include TagQuarantineTestHelper

  REFUSAL = "This request names a tag only an admin may change. Ask an admin to make it"

  setup do
    @tunnel = create(:approver_user, name: "tunnel")
    @admin = create(:admin_user)
    assert(TagBanishment.pipeline?(@tunnel))
    banish_tags!("gore_thing")
    flag_tags!("secret_(thing)")
  end

  def filed(user, script)
    CurrentUser.scoped(user) do
      bur = build(:bulk_update_request, user: user, script: script)
      bur.validate
      bur
    end
  end

  should "refuse a script naming a banished tag when a posting bot files it" do
    assert_equal([REFUSAL], filed(@tunnel, "update gore_thing -> -gore_thing").errors.full_messages)
  end

  should "refuse a script naming a flagged tag when a posting bot files it" do
    assert_equal([REFUSAL], filed(@tunnel, "update secret_(thing) -> other_thing").errors.full_messages)
  end

  should "still let an admin file a script naming a flagged tag, and a bot file an ordinary one" do
    assert_equal([], filed(@admin, "update secret_(thing) -> other_thing").errors.full_messages)
    assert_equal([], filed(@tunnel, "update sword -> blade").errors.full_messages)
  end

  should "name the refused lines but no tag, in the sentence or in a line's reason" do
    bur = filed(@tunnel, "update sword -> blade\nupdate gore_thing -> -gore_thing\nupdate secret_(thing) -> x")

    assert_equal([REFUSAL], bur.errors.full_messages)
    assert_equal([[2, "update gore_thing -> -gore_thing"], [3, "update secret_(thing) -> x"]], bur.line_errors.map { |e| [e[:line], e[:text]] })
    bur.line_errors.each { |e| assert_equal("This line names a tag only an admin may change", e[:reason]) }
  end

  # The script's own checks run with the system account's sight, so their
  # words can name a quarantined tag the script never does: "spoiler_x is
  # already aliased to gore_thing". What the bot relays names none of them.
  context "refused by a check whose words would name a hidden tag" do
    setup do
      create(:tag_alias, antecedent_name: "spoiler_x", consequent_name: "gore_thing")
      create(:tag_alias, antecedent_name: "hush_x", consequent_name: "secret_(thing)")
    end

    should "name neither the hidden tag nor drop the line, for a posting bot" do
      bur = filed(@tunnel, "update sword -> blade\ncreate alias foo -> spoiler_x\ncreate alias bar -> hush_x")

      words = (bur.errors.full_messages + bur.line_errors.pluck(:reason)).join("\n")
      assert_no_match(/gore_thing|gore thing|secret_\(thing\)|secret \(thing\)/, words)
      assert_equal([[2, "create alias foo -> spoiler_x"], [3, "create alias bar -> hush_x"]], bur.line_errors.map { |e| [e[:line], e[:text]] })
      bur.line_errors.each { |e| assert_equal("This line conflicts with a tag only an admin may change", e[:reason]) }
      assert_equal(["A line conflicts with a tag only an admin may change. Ask an admin to make it"], bur.errors.full_messages)
    end

    should "keep the words of a check that names no hidden tag" do
      create(:tag_alias, antecedent_name: "plain_y", consequent_name: "plain_z")
      bur = filed(@tunnel, "create alias foo -> plain_y\ncreate alias bar -> spoiler_x")

      assert_includes(bur.errors.full_messages, "Can't create alias [[foo]] -> [[plain_y]] (plain_y is already aliased to plain_z)")
      assert_equal("Can't create alias [[foo]] -> [[plain_y]] (plain_y is already aliased to plain_z)", bur.line_errors.first[:reason])
      assert_equal("This line conflicts with a tag only an admin may change", bur.line_errors.second[:reason])
    end

    should "withhold a hidden name written with spaces or in brackets, but not a longer name that starts with it" do
      messages, line_errors = BulkUpdateRequest.new.withheld(
        ["x is aliased to gore thing", "gore_thingy is a different tag", "y (gore_thing)"],
        [{ line: 1, text: "alias a -> b", reason: "see [[gore_thing]]" }],
        User.anonymous,
      )

      assert_equal(["A line conflicts with a tag only an admin may change. Ask an admin to make it", "gore_thingy is a different tag"], messages)
      assert_equal([{ line: 1, text: "alias a -> b", reason: "This line conflicts with a tag only an admin may change" }], line_errors)
    end

    should "hold a person filing on the booru to their own sight, and an admin to theirs" do
      member = create(:user)
      words = ->(bur) { (bur.errors.full_messages + bur.line_errors.pluck(:reason)).join("\n") }

      assert_no_match(/gore_thing|secret_\(thing\)/, words.call(filed(member, "create alias foo -> spoiler_x\ncreate alias bar -> hush_x")))
      admin = words.call(filed(@admin, "create alias foo -> spoiler_x\ncreate alias bar -> hush_x"))
      assert_no_match(/gore_thing/, admin) # banished: hidden from all but the pipeline
      assert_match(/hush_x is already aliased to secret_\(thing\)/, admin) # flagged: an admin sees it
    end
  end

  should "refuse a bot's edit that puts a banished tag into its own request" do
    bur = CurrentUser.scoped(@tunnel) { create(:bulk_update_request, user: @tunnel, script: "update sword -> blade") }

    CurrentUser.scoped(@tunnel) { assert_equal(false, bur.update(script: "update gore_thing -> -gore_thing")) }
    assert_equal([REFUSAL], bur.errors.full_messages)
    assert_equal("update sword -> blade", bur.reload.script)
  end
end
