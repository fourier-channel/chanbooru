# frozen_string_literal: true

require "test_helper"

# The original date (posts.source_created_at): what a sender may give, what a
# post given none gets, how it is searched and sorted, and the backfill that
# dates the posts made before senders gave it (SourceDateBackfill).
class PostSourceDateTest < ActiveSupport::TestCase
  setup do
    CurrentUser.user = create(:user)
  end

  teardown do
    CurrentUser.user = nil
  end

  context "A new post" do
    should "be dated when the booru received it, marked added, when no date is given" do
      post = create(:post)
      assert_in_delta(post.created_at.to_f, post.source_created_at.to_f, 5)
      assert_equal("added", post.source_created_at_precision)
      assert_not(post.source_date_known?)
    end

    should "keep a given date as exact when no precision is given" do
      post = create(:post, source_created_at: "2019-03-04T05:06:07Z")
      assert_equal(Time.utc(2019, 3, 4, 5, 6, 7), post.source_created_at)
      assert_equal("exact", post.source_created_at_precision)
      assert(post.source_date_known?)
    end

    should "keep a given precision" do
      post = create(:post, source_created_at: "2019-03-04T05:06:07+09:00", source_created_at_precision: "estimated")
      assert_equal(Time.utc(2019, 3, 3, 20, 6, 7), post.source_created_at)
      assert_equal("estimated", post.source_created_at_precision)
    end

    should "refuse a date it cannot read, or one without its zone, naming the fix" do
      ["last tuesday", "2019-03-04", "2019-03-04T05:06:07", "2019-13-45T05:06:07Z"].each do |given|
        post = build(:post, source_created_at: given)
        assert_not(post.valid?, given)
        assert_match(/could not be read as a time.*Fix: send an ISO 8601 time/, post.errors[:source_created_at].join, given)
      end
    end

    should "refuse a date before the floor, which is seconds read as milliseconds" do
      post = build(:post, source_created_at: Time.zone.at(1_551_675_967 / 1000.0))
      assert_not(post.valid?)
      assert_match(/is before 1990.*Fix:/, post.errors[:source_created_at].join)
    end

    should "refuse a date in the future" do
      post = build(:post, source_created_at: 1.day.from_now)
      assert_not(post.valid?)
      assert_match(/is in the future.*Fix:/, post.errors[:source_created_at].join)
    end

    should "accept a date a sender's clock puts a little ahead" do
      assert(build(:post, source_created_at: 1.minute.from_now).valid?)
    end

    should "refuse an unknown precision, and a precision without a date" do
      post = build(:post, source_created_at: "2019-03-04T05:06:07Z", source_created_at_precision: "roughly")
      assert_not(post.valid?)
      assert_match(/must be exact, estimated, or added/, post.errors[:source_created_at_precision].join)

      post = build(:post, source_created_at_precision: "exact")
      assert_not(post.valid?)
      assert_match(/without a source_created_at/, post.errors[:source_created_at_precision].join)
    end
  end

  context "Searching" do
    setup do
      # Midday, so the day is the same in the booru's time zone, which
      # posted: reads days in, as date: does.
      @old = create(:post, tag_string: "sdtest", source_created_at: "2016-05-01T12:00:00Z")
      @older = create(:post, tag_string: "sdtest", source_created_at: "2014-05-01T12:00:00Z")
      @new = create(:post, tag_string: "sdtest")
    end

    should "find posts by their original date with posted:" do
      assert_equal([@old.id], Post.user_tag_match("sdtest posted:2016-05-01").map(&:id))
      assert_equal([@older.id, @old.id].sort, Post.user_tag_match("sdtest posted:<2017-01-01").map(&:id).sort)
    end

    should "order by the original date with order:posted, newest first, and order:posted_asc" do
      assert_equal([@new.id, @old.id, @older.id], Post.user_tag_match("sdtest order:posted").map(&:id))
      assert_equal([@older.id, @old.id, @new.id], Post.user_tag_match("sdtest order:posted_asc").map(&:id))
    end

    should "list a posted: search by the original date, as date: is by created_at" do
      query = PostQuery.normalize("posted:2016-05-01", current_user: CurrentUser.user)
      assert_equal("posted_desc", query.builder.effective_order(query))
      query = PostQuery.normalize("posted:2016-05-01 order:id", current_user: CurrentUser.user)
      assert_equal("posted_asc", query.builder.effective_order(query))
    end
  end

  context "The backfill" do
    setup do
      # The backfill ran while the columns were nullable (deploy 1); they are
      # NOT NULL since 20261123000001, so the constraint is lifted inside this
      # test's own transaction, which rolls back. It runs before any post is
      # created: an insert leaves deferred FK checks pending on posts, and
      # ALTER TABLE refuses a table with pending trigger events. A re-run on
      # NOT NULL data (a better file replacing estimates) is the "never
      # lower" case below.
      Post.connection.execute("ALTER TABLE posts ALTER COLUMN source_created_at DROP NOT NULL, ALTER COLUMN source_created_at_precision DROP NOT NULL")
      @chan = create(:post, source: "https://boards.4chan.org/g/thread/100#p101")
      @chan2 = create(:post, source: "https://boards.4chan.org/g/thread/100#p102")
      # Message 1103717516193107968 was sent 2023-05-04T16:19:21.940Z.
      @discord = create(:post, source: "https://discord.com/channels/1/2/1103717516193107968")
      @other = create(:post, source: "https://example.com/a.png")
      # Posts made before senders gave a date: undated.
      Post.where(id: [@chan, @chan2, @discord, @other].map(&:id)).update_all(source_created_at: nil, source_created_at_precision: nil)
      @out = StringIO.new
      @backfill = SourceDateBackfill.new(out: @out, batch: 2, pause: 0)
    end

    should "import a file, matching sources exactly, and count what matched nothing" do
      file = StringIO.new(<<~CSV)
        https://boards.4chan.org/g/thread/100#p101,2012-01-02T03:04:05Z,exact
        https://boards.4chan.org/g/thread/100#p102,2012-01-02T03:09:00Z,estimated
        https://boards.4chan.org/g/thread/100#p999,2012-01-02T03:10:00Z,exact
      CSV
      result = @backfill.import(file)

      assert_equal({ lines: 3, matched: 2, written: 2 }, result)
      assert_equal([Time.utc(2012, 1, 2, 3, 4, 5), "exact"], @chan.reload.slice(:source_created_at, :source_created_at_precision).values)
      assert_equal("estimated", @chan2.reload.source_created_at_precision)
      assert_nil(@discord.reload.source_created_at)
      assert_match(/1 lines matched no post/, @out.string)
    end

    should "never lower what is known, so a pass can be re-run" do
      @chan.update_columns(source_created_at: Time.utc(2012, 1, 2), source_created_at_precision: "exact")
      result = @backfill.import(StringIO.new("https://boards.4chan.org/g/thread/100#p101,2013-01-01T00:00:00Z,estimated\n"))

      assert_equal(0, result[:written])
      assert_equal(Time.utc(2012, 1, 2), @chan.reload.source_created_at)
    end

    should "refuse a file that names a source twice, or a precision it does not know, before writing" do
      twice = "https://boards.4chan.org/g/thread/100#p101,2012-01-02T03:04:05Z,exact\n" * 2
      assert_raises(SourceDateBackfill::Refused) { @backfill.import(StringIO.new(twice)) }
      assert_raises(ActiveRecord::StatementInvalid, PG::Error) do
        Post.transaction(requires_new: true) { @backfill.import(StringIO.new("https://boards.4chan.org/g/thread/100#p101,2012-01-02T03:04:05Z,added\n")) }
      end
      assert_nil(@chan.reload.source_created_at)
    end

    should "date Discord permalinks from the message snowflake" do
      result = @backfill.discord

      assert_equal(1, result[:matched])
      assert_equal(1, result[:written])
      assert_equal("exact", @discord.reload.source_created_at_precision)
      assert_in_delta(Time.utc(2023, 5, 4, 16, 19, 21.94).to_f, @discord.source_created_at.to_f, 0.001)
    end

    should "date the rest with created_at, marked added, and leave dated posts alone" do
      @chan.update_columns(source_created_at: Time.utc(2012, 1, 2), source_created_at_precision: "exact")
      @backfill.rest

      assert_equal("added", @other.reload.source_created_at_precision)
      assert_in_delta(@other.created_at.to_f, @other.source_created_at.to_f, 0.001)
      assert_equal(Time.utc(2012, 1, 2), @chan.reload.source_created_at)
      assert_equal(0, Post.where(source_created_at: nil).count)
    end

    should "count posts per precision" do
      counts = @backfill.report
      assert_equal(4, counts["none"])
    end
  end
end
