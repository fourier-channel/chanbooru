require "test_helper"

# THE ONE RULE for creator-only data (operator ruling 2026-09-29), asked
# directly. The functional test asks the same questions at every door; this
# one pins the rule itself, including the bulk form every gallery uses, so the
# two forms cannot drift apart.
class FourierCreatorPrivacyTest < ActiveSupport::TestCase
  CREATOR = "@alice:41chan.net"

  def identity(mxid)
    ActionDispatch::TestRequest.create("HTTP_X_FOURIER_IDENTITY" => mxid)
  end

  def visible?(post, user, request = nil)
    FourierCreatorPrivacy.visible_to?(post, user, request)
  end

  context "FourierCreatorPrivacy" do
    setup do
      # The tunnel's account as production names it; the list is the real one
      # (Danbooru.config.fourier_posting_bot_names), not a stub. Round two
      # stubbed it with each file's own bot, so the real value -- which named
      # no real bot -- was never asked (round-two finding 4).
      @bot = create(:builder_user, name: "tunnel")
      @post = create(:post, uploader: @bot, tag_string: "41chan_alice landscape")
      FourierPostCreator.create!(post: @post, mxid: CREATOR, recorded_by: @bot.id)
      @member = create(:user)
    end

    should "admit the recorded creator by verified identity, case-insensitively" do
      assert visible?(@post, User.anonymous, identity(CREATOR))
      assert visible?(@post, @member, identity("@ALICE:41chan.net"))
    end

    should "admit no role: not an admin, a moderator, the owner, the bot, a member or a stranger" do
      [create(:admin_user), create(:moderator_user), create(:owner_user), @bot, @member, User.anonymous, nil].each do |user|
        refute visible?(@post, user), user&.level_string.inspect
        refute visible?(@post, user, identity("@mallory:41chan.net")), user&.level_string.inspect
      end
    end

    should "not take the creator from the post's tags" do
      # A member adds their own poster tag, and even presents their own
      # verified identity for it: a tag is not a recorded creator.
      @post.update_columns(tag_string: "41chan_alice 41chan_mallory landscape")
      refute visible?(@post, @member, identity("@mallory:41chan.net"))
    end

    # Decision 2026-09-29: only the creator decides, and a grant is a
    # moderator's row. Every ability a row can carry, on the creator's own
    # poster tag and on a tag the post carries, as rows already on record
    # (a new view grant cannot be created at all). Round-two finding 17: a
    # grant of the wrong ability was never asked.
    should "open nothing through a grant of any ability on any tag" do
      TagGrant::ABILITIES.each do |ability|
        %w[41chan_alice landscape].each do |tag|
          TagGrant.new(user: @member, tag: tag, ability: ability).save!(validate: false)
        end
      end
      assert_equal TagGrant::ABILITIES.size * 2, TagGrant.where(user: @member).count

      refute visible?(@post, @member)
      refute visible?(@post, @member, identity("@mallory:41chan.net"))
      assert_empty FourierCreatorPrivacy.readable_post_ids([@post], @member, nil)
      assert visible?(@post, @member, identity(CREATOR)), "the creator's own identity still opens it"
    end

    should "open nothing through a grant for a creator whose post lost its poster tag, or a remote creator" do
      @post.update_columns(tag_string: "landscape")
      remote = create(:post, uploader: @bot, tag_string: "41chan_alice")
      FourierPostCreator.create!(post: remote, mxid: "@alice:elsewhere.org", recorded_by: @bot.id)
      TagGrant.new(user: @member, tag: "41chan_alice", ability: "view").save!(validate: false)

      refute visible?(@post, @member)
      refute visible?(remote, @member)
      assert visible?(remote, User.anonymous, identity("@alice:elsewhere.org"))
    end

    should "fall back to a human uploader when nothing is recorded, and only then" do
      person = create(:user)
      own = create(:post, uploader: person)
      assert visible?(own, person)
      refute visible?(own, create(:admin_user))
      refute visible?(own, @member)
      refute visible?(own, User.anonymous)

      # A recorded creator replaces the uploader entirely.
      FourierPostCreator.create!(post: own, mxid: "@someone:41chan.net", recorded_by: @bot.id)
      refute visible?(own, person)
    end

    should "never make a posting bot a creator, so an unrecorded bot post is nobody's" do
      orphan = create(:post, uploader: @bot, tag_string: "41chan_alice")
      refute visible?(orphan, @bot)
      refute visible?(orphan, User.anonymous, identity(CREATOR)), "the tag named someone, and that is not a record"
      refute visible?(orphan, create(:admin_user))

      # fourier-sampling's account is a bot as well.
      sample = create(:builder_user, name: "sample")
      scraped = create(:post, uploader: sample)
      refute visible?(scraped, sample)
    end

    # The production names, by the real list: `sample` and `tunnel`, in any
    # case. Nothing else -- not `bmb`, the tunnel's repo, nor `bridge`, the
    # tunnel's account before 2026-08-13 -- is a bot, so either would be a
    # person if it uploaded.
    should "know the posting bots by their production names" do
      assert_equal %w[sample tunnel], FourierCreatorPrivacy.posting_bot_names.sort
      %w[tunnel TUNNEL sample Sample].each { |name| assert FourierCreatorPrivacy.posting_bot?(User.new(name: name)), name }
      %w[bmb bridge sampling tunnel_bot].each { |name| refute FourierCreatorPrivacy.posting_bot?(User.new(name: name)), name }
    end

    should "read a DANBOORU_FOURIER_POSTING_BOT_NAMES override as a list, not as one name" do
      Danbooru.config.stubs(:fourier_posting_bot_names).returns("sample, tunnel other")
      assert_equal %w[sample tunnel other], FourierCreatorPrivacy.posting_bot_names
      assert FourierCreatorPrivacy.posting_bot?(User.new(name: "other"))
    end

    should "answer a page in bulk exactly as it answers each post" do
      person = create(:user)
      TagGrant.new(user: person, tag: "41chan_alice", ability: "view").save!(validate: false)
      posts = [@post, create(:post, uploader: person), create(:post, uploader: @bot), create(:post)]
      [[person, nil], [person, identity(CREATOR)], [@member, identity(CREATOR)], [@bot, nil], [User.anonymous, nil]].each do |user, request|
        bulk = FourierCreatorPrivacy.readable_post_ids(posts, user, request)
        posts.each do |post|
          assert_equal visible?(post, user, request), bulk.include?(post.id), "post #{post.id} for #{user.name}"
        end
      end
    end

    should "read a poster tag's MXID only for a safe localpart, on this server" do
      assert_equal "@alice:41chan.net", FourierCreatorPrivacy.mxid_for_poster_tag("41chan_alice")
      assert_nil FourierCreatorPrivacy.mxid_for_poster_tag("41chan_A.B")
      assert_nil FourierCreatorPrivacy.mxid_for_poster_tag("4chan_alice")
    end
  end
end
