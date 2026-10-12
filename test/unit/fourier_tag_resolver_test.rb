# frozen_string_literal: true

require "test_helper"

# FourierTagResolver: a prompt-derived name -> the tag this booru already has
# for it. It had no tests of its own until 2026-10-12, when the original-
# character scheme gave the bracket a second meaning: in hilda_(pokemon) it
# names a SERIES, in kayla_(selphdestruct) a CREATOR. The resolver's two
# cross-bracket guesses were written for series only, and on OC names they
# mis-attribute a picture to someone else's character (operator, 2026-10-12:
# "multiple conflicting uses of the same dataspace by different things").
class FourierTagResolverTest < ActiveSupport::TestCase
  setup do
    @admin = create(:admin_user)
  end

  def tag!(name, category)
    as(@admin) { create(:post, tag_string: name) }
    Tag.find_by_name(name).tap { |t| t.update!(category: TagCategory.mapping[category], updater: @admin) }
  end

  def resolve(name)
    FourierTagResolver.resolve([name])[name]
  end

  context "the steps that never cross a bracket" do
    should "follow an alias" do
      tag!("bar", "general")
      as(@admin) { TagAlias.approve!(antecedent_name: "foo", consequent_name: "bar", approver: @admin) }

      assert_equal("bar", resolve("foo"))
    end

    should "leave a name that exists, and one nothing matches, as itself" do
      tag!("landscape", "general")

      assert_equal("landscape", resolve("landscape"))
      assert_equal("no_such_thing", resolve("no_such_thing"))
    end
  end

  context "a plain name and a qualified tag of the same stem" do
    should "find the one series character: hilda -> hilda_(pokemon)" do
      tag!("hilda_(pokemon)", "character")

      assert_equal("hilda_(pokemon)", resolve("hilda"))
    end

    should "guess nothing when two share the stem" do
      tag!("hilda_(pokemon)", "character")
      tag!("hilda_(fire_emblem)", "character")

      assert_equal("hilda", resolve("hilda"))
    end

    should "never land on an original character: kayla is not selphdestruct's kayla_(selphdestruct)" do
      tag!("kayla_(selphdestruct)", "character")
      tag!("original", "copyright")
      as(@admin) { TagImplication.approve!(antecedent_name: "kayla_(selphdestruct)", consequent_name: "original", approver: @admin) }

      assert_equal("kayla", resolve("kayla"))
    end

    should "never land on a claimed character either, implication or not" do
      tag!("kayla_(selphdestruct)", "character")
      CharacterClaim.create!(tag_name: "kayla_(selphdestruct)", creator_slug: "selphdestruct", status: "held", approver: @admin)

      assert_equal("kayla", resolve("kayla"))
    end
  end

  context "a qualified name the booru does not have" do
    should "fold a series' character onto its stem: hatsune_miku_(vocaloid) -> hatsune_miku" do
      tag!("hatsune_miku", "character")
      tag!("vocaloid", "copyright")

      assert_equal("hatsune_miku", resolve("hatsune_miku_(vocaloid)"))
    end

    should "not fold a creator's character onto a stranger of the same name" do
      tag!("kayla", "character")

      assert_equal("kayla_(selphdestruct)", resolve("kayla_(selphdestruct)"))
    end
  end
end
