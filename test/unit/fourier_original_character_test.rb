# frozen_string_literal: true

require "test_helper"

# THE ORIGINAL-CHARACTER RULE at post time. A name in the hub's `oc` list is
# declared -- on the post, public, filed as a character -- when it is:
#
# - <name>_(<the poster's own localpart>) (operator ruling 2026-10-11), the
#   poster being the account recorded as the post's creator
#   (FourierPostCreator), never the posting bot, and only on this homeserver;
#   checked by CharacterClaim's name rule, and never re-filing a general tag
#   that already has posts. Refused by name, with the fix, otherwise.
# - <name>_(<anyone>) that is ALREADY an established original character (a
#   character tag implying `original`), from anyone's prompt (2026-10-12).
#   Declaring confers no ownership.
# - a name in one of the 2026-09-19 shapes (oc_<name>, character_oc_<name>,
#   <name>_oc, <name>_character_oc), whoever posted it (operator, 2026-10-12:
#   "continue to accept the pre-existing format but prepare for them to be
#   changed manually for the first few"): as ITSELF while no alias moves it,
#   and as the alias's consequent once one does. Never rewritten from the
#   poster -- the poster is not the creator.
#
# A qualified name that is neither the poster's own nor an established
# original character is an ordinary private prompt term: kept (the tunnel
# sends it in the creator list too), never declared, and never reported as a
# refusal -- saber_(fate) is not an error.
class FourierOriginalCharacterTest < ActiveSupport::TestCase
  setup do
    CreatorPrefixes.reset!
    @tunnel = create(:builder_user, name: "tunnel")
    @post = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "landscape") }
  end

  def record(sources)
    FourierTagSource.record_partition!(@post, sources, @tunnel)
  end

  def creator!(mxid)
    FourierPostCreator.create!(post: @post, mxid: mxid, recorded_by: @tunnel.id)
  end

  should "declare the poster's own <name>_(<localpart>): on the post, public, a character" do
    creator!("@saber:41chan.net")

    assert_equal({}, record({ oc: ["Maple_(Saber)"], auto: ["landscape"] }))

    assert_includes(@post.reload.tag_array, "maple_(saber)")
    assert(Tag.find_by_name("maple_(saber)").character?)
    row = FourierTagSource.find_by!(post_id: @post.id, tag: "maple_(saber)")
    assert(row.public?)
  end

  # The creator lists are the prompt, and the prompt is the creator's alone
  # (FourierCreatorPrivacy): a name there in the OC shape, even the poster's
  # own, stays a private creator row. Only `oc` declares.
  should "leave a name in the prompt's creator lists private, even the poster's own" do
    creator!("@saber:41chan.net")

    assert_equal({}, record({ creator: ["maple_(saber)", "hilda_(pokemon)"], both: ["style_lora_(saber)"], auto: ["style_lora_(saber)"] }))

    assert_not(FourierTagSource.find_by!(post_id: @post.id, tag: "maple_(saber)").public?)
    assert_not(FourierTagSource.find_by!(post_id: @post.id, tag: "hilda_(pokemon)").public?)
    assert_not_includes(@post.reload.tag_array, "maple_(saber)")
    assert_nil(Tag.find_by_name("maple_(saber)"))
  end

  should "refuse a name under a creator prefix, which is a creator tag and never a character" do
    creator!("@saber:41chan.net")

    refused = record({ oc: ["41chan_maple_(saber)"] })

    assert_match(/41chan_ marks creator tags, not characters: name it maple_\(saber\)/, refused["41chan_maple_(saber)"])
    assert_not_includes(@post.reload.tag_array, "41chan_maple_(saber)")
    assert_nil(Tag.find_by_name("41chan_maple_(saber)"))
  end

  # A poster whose localpart is a common qualifier must not re-file
  # somebody's big general tag because it ends in their name.
  should "never re-file a general tag that already has posts, and say how to claim it" do
    creator!("@food:41chan.net")
    create(:tag, name: "curry_(food)", category: TagCategory::GENERAL, post_count: 5000)

    refused = record({ oc: ["curry_(food)"] })

    assert_match(/curry_\(food\) is already a general tag on 5000 posts.*claim it from your creator page/, refused["curry_(food)"])
    assert(Tag.find_by_name("curry_(food)").general?)
    assert_not_includes(@post.reload.tag_array, "curry_(food)")
  end

  should "refuse a qualifier the booru gives its own meaning, whatever the poster's name" do
    creator!("@cosplay:41chan.net")

    refused = record({ oc: ["hatsune_miku_(cosplay)"] })

    assert_match(/every tag ending _\(cosplay\) a meaning of its own/, refused["hatsune_miku_(cosplay)"])
    assert_nil(Tag.find_by_name("hatsune_miku_(cosplay)"))
  end

  should "re-file an empty general tag, and declare again once it is the poster's character" do
    creator!("@saber:41chan.net")
    create(:tag, name: "maple_(saber)", category: TagCategory::GENERAL, post_count: 0)

    assert_equal({}, record({ oc: ["maple_(saber)"] }))
    assert(Tag.find_by_name("maple_(saber)").character?)

    @post = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "landscape") }
    creator!("@saber:41chan.net")
    assert_equal({}, record({ oc: ["maple_(saber)"] }), "a character tag with the creator's earlier post on it")
    assert_includes(@post.reload.tag_array, "maple_(saber)")
  end

  context "with a broken prefix list" do
    setup do
      @dir = Dir.mktmpdir("oc-prefixes")
      @path = File.join(@dir, "creator_prefixes.yml")
      @was = ENV.fetch("FOURIER_CREATOR_PREFIXES", nil)
      File.write(@path, "prefixes: [unclosed\n")
      ENV["FOURIER_CREATOR_PREFIXES"] = @path
      CreatorPrefixes.reset!
    end

    teardown do
      ENV["FOURIER_CREATOR_PREFIXES"] = @was
      CreatorPrefixes.reset!
      FileUtils.rm_rf(@dir)
    end

    should "declare nothing, and say why" do
      creator!("@saber:41chan.net")

      refused = record({ oc: ["maple_(saber)"] })

      assert_match(/creator-prefix list is broken/, refused["maple_(saber)"])
      assert_nil(Tag.find_by_name("maple_(saber)"))
    end

    # Fork: what is wrong with the list (its path on the server, the
    # parser's words) goes to the log; the refusal is words only. The
    # posting bot relays it (original_characters_not_declared), and a bot
    # posts no address into a room (technetium-81, 2026-10-19).
    should "keep the list's path and the parser's words out of the refusal, and log them" do
      Rails.logger.stubs(:error)
      Rails.logger.expects(:error).with { |message, *| message.to_s.include?("the creator-prefix list is broken: ") && message.to_s.include?(@path) }.at_least_once
      creator!("@saber:41chan.net")

      why = record({ oc: ["maple_(saber)"] })["maple_(saber)"]

      assert_not_includes(why, @dir)
      assert_no_match(/YAML|Psych|unclosed/i, why)
      assert_match(/the creator-prefix list is broken, so maple_\(saber\) cannot be checked and was not declared; the server log says what is wrong/, why)
    end
  end

  should "declare every 2026-09-19 shape with no alias AS ITSELF, whoever posted it: on the post, public, a character" do
    creator!("@saber:41chan.net")

    assert_equal({}, record({ oc: %w[oc_Kayla character_oc_pine birch_oc cedar_character_oc] }))

    tags = @post.reload.tag_array
    %w[oc_kayla character_oc_pine birch_oc cedar_character_oc].each do |name|
      assert_includes(tags, name)
      assert(Tag.find_by_name(name).character?, name)
      assert(FourierTagSource.find_by!(post_id: @post.id, tag: name).public?, name)
    end
    assert_empty(Tag.where("name LIKE '%(saber)'"), "never rewritten from the poster")
    assert_equal(0, CharacterClaim.count)
  end

  should "declare a legacy name as itself with no recorded creator, or one on another homeserver" do
    assert_equal({}, record({ oc: %w[oc_kayla] }))
    assert_includes(@post.reload.tag_array, "oc_kayla")

    @post = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "landscape") }
    creator!("@saber:elsewhere.example")
    assert_equal({}, record({ oc: %w[maple_oc] }))
    assert_includes(@post.reload.tag_array, "maple_oc")
  end

  should "keep a legacy tag's category when it is filed as something other than general" do
    create(:tag, name: "oc_kayla", category: TagCategory::COPYRIGHT)

    assert_equal({}, record({ oc: %w[oc_kayla] }))

    assert(Tag.find_by_name("oc_kayla").copyright?)
    assert_includes(@post.reload.tag_array, "oc_kayla")
  end

  should "declare a legacy name an alias has moved as the alias's consequent, whoever posted it" do
    creator!("@saber:41chan.net")
    create(:tag, name: "kayla_(selphdestruct)", category: TagCategory::CHARACTER)
    create(:tag_alias, antecedent_name: "oc_kayla", consequent_name: "kayla_(selphdestruct)")

    assert_equal({}, record({ oc: %w[oc_kayla], creator: %w[oc_kayla] }))

    tags = @post.reload.tag_array
    assert_includes(tags, "kayla_(selphdestruct)")
    assert_not_includes(tags, "oc_kayla")
    assert_not_includes(tags, "kayla_(saber)")
    row = FourierTagSource.find_by!(post_id: @post.id, tag: "kayla_(selphdestruct)")
    assert(row.public?, "declared, not the private creator row the prompt list would make")
    assert_nil(FourierTagSource.find_by(post_id: @post.id, tag: "oc_kayla"))
    assert_equal(0, CharacterClaim.count, "declaring confers no ownership")
  end

  should "never re-file an alias's consequent: its category is whoever made the alias's" do
    create(:tag, name: "kayla", category: TagCategory::GENERAL, post_count: 40)
    create(:tag_alias, antecedent_name: "kayla_oc", consequent_name: "kayla")

    assert_equal({}, record({ oc: %w[kayla_oc] }))

    assert(Tag.find_by_name("kayla").general?)
    assert_includes(@post.reload.tag_array, "kayla")
  end

  should "declare two legacy shapes moved onto one tag as one character" do
    creator!("@saber:41chan.net")
    create(:tag, name: "kayla_(selphdestruct)", category: TagCategory::CHARACTER)
    create(:tag_alias, antecedent_name: "oc_kayla", consequent_name: "kayla_(selphdestruct)")
    create(:tag_alias, antecedent_name: "kayla_oc", consequent_name: "kayla_(selphdestruct)")

    assert_equal({}, record({ oc: %w[oc_kayla kayla_oc kayla_(selphdestruct)] }))

    assert_equal(1, @post.reload.tag_array.count("kayla_(selphdestruct)"))
    assert_equal(1, FourierTagSource.where(post_id: @post.id, tag: "kayla_(selphdestruct)").count)
  end

  context "an established original character" do
    setup do
      @boss = create(:admin_user)
      create(:tag, name: "kayla_(selphdestruct)", category: TagCategory::CHARACTER)
      create(:tag, name: "original", category: TagCategory::COPYRIGHT)
      as(@boss) { TagImplication.approve!(antecedent_name: "kayla_(selphdestruct)", consequent_name: "original", approver: @boss) }
    end

    should "be declared from anyone's prompt, conferring nothing" do
      creator!("@saber:41chan.net")

      assert_equal({}, record({ oc: %w[kayla_(selphdestruct)], creator: %w[kayla_(selphdestruct)] }))

      assert_includes(@post.reload.tag_array, "kayla_(selphdestruct)")
      assert(FourierTagSource.find_by!(post_id: @post.id, tag: "kayla_(selphdestruct)").public?)
      assert_equal(0, CharacterClaim.count)
    end

    should "be declared even while the post has no recorded creator" do
      assert_equal({}, record({ oc: %w[kayla_(selphdestruct)] }))

      assert_includes(@post.reload.tag_array, "kayla_(selphdestruct)")
    end
  end

  should "keep someone else's qualified name, not an established original character, as a silent private prompt term" do
    creator!("@saber:41chan.net")
    create(:tag, name: "saber_(fate)", category: TagCategory::CHARACTER, post_count: 900)

    refused = record({ oc: %w[saber_(fate) maple_(bob)], creator: %w[saber_(fate) maple_(bob)] })

    assert_equal({}, refused, "not a refusal: saber_(fate) is not an error")
    %w[saber_(fate) maple_(bob)].each do |name|
      row = FourierTagSource.find_by!(post_id: @post.id, tag: name)
      assert_not(row.public?, name)
      assert_not_includes(@post.reload.tag_array, name)
    end
    assert_nil(Tag.find_by_name("maple_(bob)"))
    assert(Tag.find_by_name("saber_(fate)").character?)
  end

  should "declare nothing under anyone's name while the post has no recorded creator" do
    refused = record({ oc: ["maple_(saber)"], creator: ["pine_(tunnel)"] })

    assert_match(%r{post ##{@post.id} has no recorded creator.*POST /fourier/posts/#{@post.id}/creator.json}, refused["maple_(saber)"])
    assert_not(refused.key?("pine_(tunnel)"), "a creator-list name is an ordinary private creator row")
    assert_not(FourierTagSource.find_by!(post_id: @post.id, tag: "pine_(tunnel)").public?, "named for the bot, not the creator")
    assert_nil(Tag.find_by_name("maple_(saber)"))
  end

  # THE CONTRACT WITH THE TUNNEL: a qualified name in `oc` that is ALSO in the
  # creator lists (creator or both) is OFFERED -- declared if it is the
  # recorded creator's own or an established original character, otherwise
  # a silent private term. A Discord post records no creator, and the tunnel
  # offers every qualified name there: saber_(fate) is not an error on it.
  should "say nothing about an offered name while the post has no recorded creator, keeping it private" do
    refused = record({ oc: %w[saber_(fate) maple_(bob)], creator: %w[saber_(fate)], both: %w[maple_(bob)], auto: %w[maple_(bob)] })

    assert_equal({}, refused, "an offer is never a refusal")
    assert_not(FourierTagSource.find_by!(post_id: @post.id, tag: "saber_(fate)").public?)
    assert_not_includes(@post.reload.tag_array, "saber_(fate)")
  end

  should "say nothing about an offered name from an account on another homeserver" do
    creator!("@saber:elsewhere.example")

    assert_equal({}, record({ oc: %w[saber_(fate)], creator: %w[saber_(fate)] }))
    assert_not(FourierTagSource.find_by!(post_id: @post.id, tag: "saber_(fate)").public?)
  end

  # A name in `oc` ALONE is the tunnel saying "the poster's own". If the
  # booru's recorded creator is someone else, it is not declared -- and it is
  # in no other list, so silence would lose it: it is refused by name.
  should "refuse by name, never drop, a name sent in oc alone that is not the recorded creator's" do
    creator!("@alice:41chan.net")

    refused = record({ oc: %w[maple_(saber)] })

    assert_match(/maple_\(saber\) names saber, but post ##{@post.id} was made by @alice:41chan\.net/, refused["maple_(saber)"])
  end

  should "declare an offered name that is the recorded creator's own" do
    creator!("@saber:41chan.net")

    assert_equal({}, record({ oc: %w[maple_(saber)], creator: %w[maple_(saber)] }))
    assert_includes(@post.reload.tag_array, "maple_(saber)")
    assert(FourierTagSource.find_by!(post_id: @post.id, tag: "maple_(saber)").public?)
  end

  should "declare nothing for an account on another homeserver" do
    creator!("@saber:elsewhere.example")

    refused = record({ oc: ["maple_(saber)"] })

    assert_match(/@saber:elsewhere\.example is not an account on 41chan\.net/, refused["maple_(saber)"])
  end

  should "refuse a tag filed as something other than general or character, keeping its category" do
    creator!("@saber:41chan.net")
    create(:tag, name: "maple_(saber)", category: TagCategory::COPYRIGHT)

    refused = record({ oc: ["maple_(saber)"] })

    assert_match(/maple_\(saber\) is filed as copyright: ask an admin to re-file it as a character/, refused["maple_(saber)"])
    assert(Tag.find_by_name("maple_(saber)").copyright?)
    assert_not_includes(@post.reload.tag_array, "maple_(saber)")
  end
end
