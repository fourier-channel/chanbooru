# frozen_string_literal: true

require "test_helper"

# FLAGGED-TAG QUARANTINE (operator rulings 2026-10-12): the table of tags out
# of normal circulation -- flagged for review, or banished -- and the one
# place that says who sees what of them.
class TagQuarantineTest < ActiveSupport::TestCase
  def md5 = SecureRandom.hex(16)

  setup do
    @admin = create(:admin_user)
    @owner = create(:owner_user)
    @member = create(:user)
    @moderator = create(:moderator_user)
    @approver = create(:approver_user)
    @tunnel = create(:approver_user, name: "tunnel")
    @sample = create(:approver_user, name: "sample")
    @secret = create(:tag, name: "secret_(thing)")
    @gore = create(:tag, name: "gore_thing")
  end

  context "Who sees a flagged tag's posts" do
    should "be every post for Admin and Owner level and the system user" do
      [@admin, @owner, User.system].each do |user|
        assert_equal :all, TagQuarantine.flagged_posts_visible_to(user), user.name
      end
    end

    should "be only their own for a posting bot" do
      [@tunnel, @sample].each do |bot|
        assert_equal :own, TagQuarantine.flagged_posts_visible_to(bot), bot.name
      end
    end

    should "be none for everyone else" do
      [nil, User.anonymous, @member, @moderator, @approver, create(:gold_user), create(:builder_user)].each do |user|
        assert_equal :none, TagQuarantine.flagged_posts_visible_to(user), user&.level_string.to_s
      end
    end

    should "be every post for a bot account raised to admin" do
      @sample.update!(level: User::Levels::ADMIN)
      assert_equal :all, TagQuarantine.flagged_posts_visible_to(@sample)
    end
  end

  context "The sets" do
    should "be read from the table, and forgotten the moment a row changes" do
      assert_empty TagQuarantine.flagged_names
      row = TagQuarantine.flag!(@secret, by: @admin, note: "review")
      assert_equal Set["secret_(thing)"], TagQuarantine.flagged_names

      row.banish!(by: @admin, note: "out")
      assert_empty TagQuarantine.flagged_names
      assert_equal Set["secret_(thing)"], TagQuarantine.banished_names
    end

    should "never rescue an unreadable read: the request fails instead of showing" do
      TagQuarantine.stubs(:joins).raises(ActiveRecord::StatementInvalid, "boom")
      CreatorVisibility.forget!
      assert_raises(ActiveRecord::StatementInvalid) { TagQuarantine.sets }
    end

    should "give a names generation that moves with the names" do
      before = TagQuarantine.names_generation
      TagQuarantine.flag!(@secret, by: @admin, note: "")
      assert_match(/\A\h{12}\z/, TagQuarantine.names_generation)
      assert_not_equal before, TagQuarantine.names_generation
    end
  end

  context "Hidden names" do
    setup do
      TagQuarantine.flag!(@secret, by: @admin, note: "")
      TagQuarantine.flag!(@gore, by: @admin, note: "").banish!(by: @admin, note: "")
    end

    should "withhold a flagged name from everyone below admin and a banished one from all but the pipeline" do
      assert_equal %w[gore_thing secret_(thing)], TagQuarantine.hidden_names_for(@member).sort
      assert_equal %w[gore_thing secret_(thing)], TagQuarantine.hidden_names_for(User.anonymous).sort
      assert_equal %w[gore_thing secret_(thing)], TagQuarantine.hidden_names_for(@moderator).sort
      assert_equal %w[gore_thing], TagQuarantine.hidden_names_for(@admin)
      assert_equal %w[gore_thing], TagQuarantine.hidden_names_for(@owner)
      assert_equal [], TagQuarantine.hidden_names_for(@tunnel)
      assert_equal [], TagQuarantine.hidden_names_for(User.system)
    end
  end

  context "Flagging, releasing and banishing" do
    should "log each in the mod log, admins only, never naming a banished tag" do
      row = TagQuarantine.flag!(@secret, by: @admin, note: "looks wrong")
      flag = ModAction.last
      assert_equal "tag_flag", flag.category
      assert_equal @secret, flag.subject
      assert_includes flag.description, "secret_(thing)"
      assert_includes flag.description, "looks wrong"
      assert_includes ModAction::ADMIN_ONLY_CATEGORIES, :tag_flag

      row.banish!(by: @admin, note: "confirmed")
      banish = ModAction.last
      assert_equal "tag_banish", banish.category
      assert_not_includes banish.description, "secret"
      assert_includes banish.description, "##{@secret.id}"
      assert_equal "banished", row.reload.state
      assert_equal @admin, row.banished_by
      assert_not_nil row.banished_at
    end

    should "release a flagged tag back to normal by deleting its row" do
      row = TagQuarantine.flag!(@secret, by: @admin, note: "")
      row.release!(by: @admin, note: "fine after all")

      assert_not TagQuarantine.exists?(tag_id: @secret.id)
      assert_equal "tag_flag_release", ModAction.last.category
      assert_empty TagQuarantine.flagged_names
    end

    should "refuse to release a banished tag, naming why" do
      row = TagQuarantine.flag!(@secret, by: @admin, note: "")
      row.banish!(by: @admin, note: "")
      error = assert_raises(TagQuarantine::Refused) { row.release!(by: @admin, note: "") }
      assert_match(/banished/, error.message)
    end

    should "refuse to flag a tag that is already banished" do
      TagQuarantine.flag!(@secret, by: @admin, note: "").banish!(by: @admin, note: "")
      assert_raises(TagQuarantine::Refused) { TagQuarantine.flag!(@secret, by: @admin, note: "") }
    end

    # Operator ruling 2026-10-12: the jail panel unbanishes (sampling's
    # account, naming the panel user who pressed it). Back to normal: the
    # row goes, and no jailed post is released.
    should "unbanish a banished tag, logging the panel user, admins only" do
      row = TagQuarantine.flag!(@gore, by: @admin, note: "")
      row.banish!(by: @admin, note: "")
      row.reload.unbanish!(by: @sample, panel_user: "@saber:41chan.net", note: "a false positive")

      assert_empty TagQuarantine.banished_names
      assert_not TagQuarantine.exists?(tag_id: @gore.id)
      log = ModAction.last
      assert_equal "tag_unbanish", log.category
      assert_equal @sample, log.creator
      assert_includes log.description, "@saber:41chan.net"
      assert_includes log.description, "a false positive"
      assert_includes ModAction::ADMIN_ONLY_CATEGORIES, :tag_unbanish
    end

    should "refuse to unbanish a tag that is only flagged" do
      row = TagQuarantine.flag!(@secret, by: @admin, note: "")
      assert_raises(TagQuarantine::Refused) { row.unbanish!(by: @sample, panel_user: "@saber:41chan.net") }
      assert TagQuarantine.flagged_names.include?("secret_(thing)")
    end

    should "queue the jailing of every carrier after a banish commits" do
      row = TagQuarantine.flag!(@secret, by: @admin, note: "")
      assert_enqueued_with(job: BanishTagJob, args: [@secret.id, @admin.id]) do
        row.banish!(by: @admin, note: "")
      end
    end
  end

  context "The quarantine document" do
    setup do
      @uploader = create(:user)
      @flagged_post = as(@uploader) { create(:post, tag_string: "landscape secret_(thing)", md5: md5, source: "mxc://41chan.net/abc", uploader: @uploader) }
      @banished_post = as(@uploader) { create(:post, tag_string: "landscape gore_thing", md5: md5, uploader: @uploader) }
      @plain = as(@uploader) { create(:post, tag_string: "landscape", md5: md5, uploader: @uploader) }
      @deleted_flagged = as(@uploader) { create(:post, tag_string: "secret_(thing)", md5: md5, uploader: @uploader, is_deleted: true) }
      TagQuarantine.flag!(@secret, by: @admin, note: "")
      TagQuarantine.flag!(@gore, by: @admin, note: "").banish!(by: @admin, note: "")
    end

    should "list every post carrying a flagged or banished name, deleted or not, in id order" do
      doc = TagQuarantine.document(reader: @tunnel, after: nil)

      assert_equal [@flagged_post.id, @banished_post.id, @deleted_flagged.id], doc[:posts].pluck(:id)
      first = doc[:posts].first
      assert_equal({ id: @flagged_post.id, md5: @flagged_post.md5, mxc: "mxc://41chan.net/abc", flagged: true, banished: false, jailed: false }, first)
      assert_nil doc[:posts].second[:mxc]
      assert_equal true, doc[:posts].second[:banished]
      assert_match(/\A\h{16}\z/, doc[:generation])
      assert_nil doc[:next_after]
    end

    should "give the names to the pipeline only" do
      pipeline = TagQuarantine.document(reader: @sample, after: nil)
      assert_equal ["secret_(thing)"], pipeline[:flagged]
      assert_equal ["gore_thing"], pipeline[:banished]

      gate = TagQuarantine.document(reader: create(:user, name: "gate"), after: nil)
      assert_nil gate[:flagged]
      assert_nil gate[:banished]
      assert_equal pipeline[:posts], gate[:posts]
    end

    should "change its generation when a post gains a quarantined tag, and only then" do
      before = TagQuarantine.document(reader: @tunnel, after: nil)[:generation]
      assert_equal before, TagQuarantine.document(reader: @tunnel, after: nil)[:generation]

      as(@admin) { @plain.update!(tag_string: "landscape secret_(thing)") }
      assert_not_equal before, TagQuarantine.document(reader: @tunnel, after: nil)[:generation]
    end

    should "page by post id, every page carrying the whole set's generation" do
      stub_const(TagQuarantine, :DOCUMENT_PAGE_SIZE, 2) do
        page1 = TagQuarantine.document(reader: @tunnel, after: nil)
        assert_equal [@flagged_post.id, @banished_post.id], page1[:posts].pluck(:id)
        assert_equal @banished_post.id, page1[:next_after]

        page2 = TagQuarantine.document(reader: @tunnel, after: page1[:next_after])
        assert_equal [@deleted_flagged.id], page2[:posts].pluck(:id)
        assert_nil page2[:next_after]
        assert_equal page1[:generation], page2[:generation]
      end
    end
  end

  # A flagged MATRIX post is reviewed in sampling's jail panel (gate 3,
  # piece E, 2026-10-15): fourier-auth's booru door no longer opens it to
  # anyone, so the booru no longer draws it there for an admin -- every
  # reader, admin included, is drawn it through the Matrix door, which
  # refuses quarantined media.
  context "Drawing a flagged Matrix post" do
    setup do
      @uploader = create(:user)
      @flagged_mxc = as(@uploader) { create(:post, tag_string: "landscape secret_(thing)", md5: md5, source: "mxc://41chan.net/abc", uploader: @uploader) }
      @plain_mxc = as(@uploader) { create(:post, tag_string: "landscape", md5: md5, source: "mxc://41chan.net/def", uploader: @uploader) }
      @flagged_web = as(@uploader) { create(:post, tag_string: "landscape secret_(thing)", md5: md5, source: "https://boards.4chan.org/x", uploader: @uploader) }
      @banished_mxc = as(@uploader) { create(:post, tag_string: "landscape secret_(thing) gore_thing", md5: md5, source: "mxc://41chan.net/ghi", uploader: @uploader) }
      @jailed_mxc = as(@uploader) { create(:post, tag_string: "landscape secret_(thing) troll_jail", md5: md5, source: "mxc://41chan.net/jkl", uploader: @uploader) }
      @own_mxc = as(@tunnel) { create(:post, tag_string: "landscape secret_(thing)", md5: md5, source: "mxc://41chan.net/pqr", uploader: @tunnel) }
      @asset_md5 = md5
      @asset = create(:media_asset, md5: @asset_md5, file_ext: "jpg")
      as(@uploader) { create(:post, tag_string: "landscape secret_(thing)", md5: @asset_md5, media_asset: @asset, source: "mxc://41chan.net/mno", uploader: @uploader) }
      TagQuarantine.flag!(@secret, by: @admin, note: "")
      TagQuarantine.flag!(@gore, by: @admin, note: "").banish!(by: @admin, note: "")
      Danbooru.config.stubs(:banished_posts_withheld?).returns(true)
    end


    # media_asset_file_url lives in the vesper local config (untracked;
    # production's copy is fourier-basis ops/hetzner/danbooru/
    # danbooru_local_config.rb). Skipped where that file is not the Fourier one.
    should "be the Matrix door for every reader, an admin included" do
      skip "needs the Fourier danbooru_local_config.rb" unless defined?(Danbooru::CustomConfiguration) && Danbooru::CustomConfiguration.method_defined?(:fourier_gate_path)
      Rails.env.stubs(:local?).returns(false)
      variant = @asset.variant(:"360x360")

      admin_url = CurrentUser.scoped(@admin) { Danbooru.config.media_asset_file_url(variant, "") }
      assert_match(%r{/_matrix/client/v1/media/thumbnail/41chan.net/mno\?}, admin_url)

      member_url = CurrentUser.scoped(@member) { Danbooru.config.media_asset_file_url(variant, "") }
      assert_match(%r{/_matrix/client/v1/media/thumbnail/41chan.net/mno\?}, member_url)
    end
  end
end
