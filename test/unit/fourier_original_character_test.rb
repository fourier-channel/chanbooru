# frozen_string_literal: true

require "test_helper"

# THE ORIGINAL-CHARACTER RULE at post time (operator ruling 2026-10-11): a
# creator names their own character <name>_(<their Matrix localpart>) in the
# hub's `oc` list, and the hub declares it -- on the post, public, filed as a
# character -- only under the name of the account recorded as the post's
# creator (FourierPostCreator), never the posting bot's, and only for an
# account on this homeserver. The prompt's private creator lists are never
# read for it, a name under a creator prefix is never one, and a tag that
# already has posts is never re-filed at post time. The oc_<name> shapes of
# 2026-09-19 are no longer read. A name that is not declared is said, with
# why and what to do, in the hub's answer.
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
  end

  should "no longer read the oc_ shapes" do
    creator!("@saber:41chan.net")

    refused = record({ oc: %w[oc_maple maple_oc] })

    assert_equal(%w[maple_oc oc_maple], refused.keys.sort)
    assert_match(/not an original character's name: name it maple_\(saber\)/, refused["oc_maple"])
    assert_nil(Tag.find_by_name("oc_maple"))
    assert_not_includes(@post.reload.tag_array, "oc_maple")
  end

  should "refuse someone else's name, and say whose post it is" do
    creator!("@saber:41chan.net")

    refused = record({ oc: ["maple_(bob)"] })

    assert_match(/maple_\(bob\) names bob, but post ##{@post.id} was made by @saber:41chan.net/, refused["maple_(bob)"])
    assert_nil(Tag.find_by_name("maple_(bob)"))
  end

  should "declare nothing under anyone's name while the post has no recorded creator" do
    refused = record({ oc: ["maple_(saber)"], creator: ["pine_(tunnel)"] })

    assert_match(%r{post ##{@post.id} has no recorded creator.*POST /fourier/posts/#{@post.id}/creator.json}, refused["maple_(saber)"])
    assert_not(refused.key?("pine_(tunnel)"), "a creator-list name is an ordinary private creator row")
    assert_not(FourierTagSource.find_by!(post_id: @post.id, tag: "pine_(tunnel)").public?, "named for the bot, not the creator")
    assert_nil(Tag.find_by_name("maple_(saber)"))
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
