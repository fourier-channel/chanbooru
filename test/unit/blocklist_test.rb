require "test_helper"

class BlocklistTest < ActiveSupport::TestCase
  def rules(blocks)
    blocks.map { |b| [b.rule, b.locked] }
  end

  context "Blocklist.parse" do
    should "read one block per line, with the lock marker as a flag" do
      text = "spider %locked\nBlue_Hair\n\n  rating:explicit   -pokemon  \nscore:<-5"

      assert_equal(
        [["spider", true], ["blue_hair", false], ["rating:e -pokemon", false], ["score:<-5", false]],
        rules(Blocklist.parse(text)),
      )
    end

    should "keep multi-tag AND lines, negation and ~ as one rule" do
      assert_equal([["insect rating:e -pokemon_(creature)", false], ["~cat ~dog", false]],
                   rules(Blocklist.parse("insect rating:e -pokemon_(creature)\n~cat ~dog")))
    end

    should "merge duplicate rules, locked if either copy was" do
      assert_equal([["spider", true]], rules(Blocklist.parse("spider\nSPIDER %locked")))
    end

    should "drop a line that holds only the marker" do
      assert_equal([], Blocklist.parse("%locked\n \n"))
    end

    # Existing lists were written for upstream's blacklist_rules; every one
    # of them must come out as the same rules (whitespace inside a line was
    # never significant: the engine splits each rule on whitespace).
    should "read every existing upstream list as the rules upstream read" do
      upstream = ->(text) { text.to_s.downcase.gsub(/(rating:\w)\w+/, '\1').lines.map(&:strip).compact_blank }
      lists = [
        "spider\nblue_hair red_eyes\n-rating:explicit cat\n",
        "Rating:Explicit\n\n\n  ~cat   ~dog  \nscore:<-3 rating:questionable\n",
        "a\tb\r\nc -d -e\n   \nuploaderid:12\nstatus:pending\n",
        "rating:general rating:sensitive\n# not a comment, a tag named #\n",
      ]
      lists.each do |text|
        assert_equal(upstream.call(text).map { |r| r.split.join(" ") }.uniq, Blocklist.parse(text).map(&:rule), text.inspect)
        assert(Blocklist.parse(text).none?(&:locked), text.inspect)
      end
    end

    should "read nil and blank as empty" do
      assert_equal([], Blocklist.parse(nil))
      assert_equal([], Blocklist.parse(""))
    end

    should "serialise to JSON as rule and locked" do
      assert_equal([{ "rule" => "spider", "locked" => true }], Blocklist.parse("spider %locked").as_json)
    end

    should "round-trip through serialize" do
      blocks = Blocklist.parse("spider %locked\nblue_hair")
      assert_equal("spider %locked\nblue_hair", Blocklist.serialize(blocks))
      assert_equal(rules(blocks), rules(Blocklist.parse(Blocklist.serialize(blocks))))
    end
  end

  context "Blocklist.edit" do
    should "add a normalised rule on a line of its own" do
      assert_equal("spider\nrating:e blue_hair", Blocklist.edit("spider", op: "add", rule: "  Rating:Explicit   Blue_Hair "))
    end

    should "do nothing when adding a rule already there" do
      assert_equal("spider %locked", Blocklist.edit("spider %locked", op: "add", rule: "SPIDER"))
    end

    should "refuse a blank rule, with the remedy" do
      error = assert_raises(Blocklist::Refused) { Blocklist.edit("", op: "add", rule: "   ") }
      assert_match(/Type a tag/, error.message)
    end

    should "refuse the lock marker typed as a tag, with the remedy" do
      error = assert_raises(Blocklist::Refused) { Blocklist.edit("", op: "add", rule: "spider %locked") }
      assert_match(/padlock/, error.message)
    end

    should "remove every line of an unlocked rule and leave the others verbatim" do
      assert_equal("Blue_Hair  red_eyes", Blocklist.edit("spider\nBlue_Hair  red_eyes\nSpider", op: "remove", rule: "spider"))
    end

    should "refuse to remove a locked rule, naming the unlock step" do
      error = assert_raises(Blocklist::Refused) { Blocklist.edit("spider %locked\ncat", op: "remove", rule: "spider") }
      assert_equal("'spider' is locked. Unlock it first (the padlock on its pill), then remove it.", error.message)
    end

    should "lock and unlock a rule in place" do
      locked = Blocklist.edit("cat\nspider\ndog", op: "lock", rule: "spider")
      assert_equal("cat\nspider %locked\ndog", locked)
      assert_equal("cat\nspider %locked\ndog", Blocklist.edit(locked, op: "lock", rule: "spider"))
      assert_equal("cat\nspider\ndog", Blocklist.edit(locked, op: "unlock", rule: "spider"))
    end

    should "unlock a marker typed in any case, and never lock twice" do
      assert_equal("spider", Blocklist.edit("spider %LOCKED", op: "unlock", rule: "spider"))
      assert_equal("spider %locked", Blocklist.edit("spider %Locked", op: "lock", rule: "spider"))
    end

    should "refuse to lock a rule that is not on the list, with the remedy" do
      error = assert_raises(Blocklist::Refused) { Blocklist.edit("cat", op: "lock", rule: "spider") }
      assert_match(/Reload the page/, error.message)
    end

    should "merge by adding only: never remove, never unlock" do
      text = Blocklist.edit("cat %locked\ndog", op: "merge", blocks: [{ "rule" => "cat", "locked" => false }, { "rule" => "Spider", "locked" => true }, { "rule" => "dog", "locked" => true }])
      assert_equal([["cat", true], ["dog", true], ["spider", true]], rules(Blocklist.parse(text)))
    end

    should "refuse an unknown op" do
      assert_raises(Blocklist::Refused) { Blocklist.edit("", op: "drop_table", rule: "x") }
    end
  end

  context "Blocklist.apply!" do
    context "for a member" do
      setup do
        @user = create(:user, blacklisted_tags: "cat")
      end

      should "write each op to the account" do
        assert_equal([["cat", false], ["spider", false]], rules(Blocklist.apply!(@user, op: "add", rule: "spider")))
        assert_equal("cat\nspider", @user.reload.blacklisted_tags)

        Blocklist.apply!(@user, op: "lock", rule: "spider")
        assert_equal("cat\nspider %locked", @user.reload.blacklisted_tags)

        assert_raises(Blocklist::Refused) { Blocklist.apply!(@user, op: "remove", rule: "spider") }
        assert_equal("cat\nspider %locked", @user.reload.blacklisted_tags)

        Blocklist.apply!(@user, op: "unlock", rule: "spider")
        Blocklist.apply!(@user, op: "remove", rule: "spider")
        assert_equal("cat", @user.reload.blacklisted_tags)
      end

      should "work on the stored list, not a stale copy" do
        stale = User.find(@user.id)
        User.find(@user.id).update!(blacklisted_tags: "cat\ndog")

        Blocklist.apply!(stale, op: "add", rule: "spider")
        assert_equal("cat\ndog\nspider", @user.reload.blacklisted_tags)
      end

      should "ignore a list sent by the client" do
        Blocklist.apply!(@user, op: "add", rule: "spider", list: [{ "rule" => "evil", "locked" => false }])
        assert_equal("cat\nspider", @user.reload.blacklisted_tags)
      end

      should "refuse past the rule limit, naming the limit" do
        stub_const(User, :MAX_BLACKLIST_RULES, 1) do
          error = assert_raises(Blocklist::Refused) { Blocklist.apply!(@user, op: "add", rule: "spider") }
          assert_match(/Blocklist can't have more than 1 blocks/, error.message)
        end
      end
    end

    context "for a signed-out viewer" do
      should "apply the op to the list the browser sent and store nothing" do
        list = [{ "rule" => "Cat", "locked" => true }]

        result = Blocklist.apply!(User.anonymous, op: "add", rule: "spider", list: list)
        assert_equal([["cat", true], ["spider", false]], rules(result))

        error = assert_raises(Blocklist::Refused) { Blocklist.apply!(User.anonymous, op: "remove", rule: "cat", list: list) }
        assert_match(/'cat' is locked/, error.message)
      end

      should "read a missing or malformed list as empty" do
        assert_equal([["spider", false]], rules(Blocklist.apply!(User.anonymous, op: "add", rule: "spider", list: nil)))
        assert_equal([["spider", false]], rules(Blocklist.apply!(User.anonymous, op: "add", rule: "spider", list: ["x", { "rule" => 5 }, 7])))
      end

      should "refuse a list past the rule limit" do
        stub_const(User, :MAX_BLACKLIST_RULES, 2) do
          list = %w[a b].map { |r| { "rule" => r, "locked" => false } }
          error = assert_raises(Blocklist::Refused) { Blocklist.apply!(User.anonymous, op: "add", rule: "c", list: list) }
          assert_match(/can't have more than 2 blocks/, error.message)
        end
      end
    end
  end
end
