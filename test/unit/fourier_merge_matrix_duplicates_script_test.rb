# frozen_string_literal: true

require "test_helper"

# script/fourier_merge_matrix_duplicates.rb, run as a person runs it: the
# file itself, with argv (operator, 2026-10-16: "No copies of objects, is a
# given. Losing visibility isn't acceptable either.").
#
# A picture that exists as two posts -- a Matrix post holding the RAW upload
# (source mxc://, posted before stripping existed) and a 4chan post holding
# the stripped bytes -- is made one post the way the tunnel's duplicate path
# makes it today: the Matrix image becomes an ALIAS (post_mxcs, source
# 'alias') of the 4chan post, which SURVIVES and stays a non-Matrix post
# (room_ids {0}); everything that hangs off the Matrix post moves to it; the
# Matrix post is RETIRED -- a child of the survivor, soft-deleted with a
# reason, an ordinary deletion and never a jailing. One transaction per pair;
# a dry run writes nothing; a rerun after --apply changes nothing.
class FourierMergeMatrixDuplicatesScriptTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("script/fourier_merge_matrix_duplicates.rb").to_s
  GATED = "child" # in Danbooru.config.restricted_tags
  MAPLE = "@maple:41chan.net"

  # [exit status, stdout, stderr]
  def run_script(*argv, stdin: nil)
    status = nil
    saved = ARGV.dup
    saved_stdin = $stdin
    ARGV.replace(argv)
    $stdin = StringIO.new(stdin) if stdin
    out, err = capture_io do
      load SCRIPT
    rescue SystemExit => e
      status = e.status
    end
    [status, out, err]
  ensure
    ARGV.replace(saved)
    $stdin = saved_stdin
  end

  def md5 = SecureRandom.hex(16)

  # Run one pair with --apply and expect it refused: exit 1, a fix on stderr.
  # Class level: shoulda runs each `should` through instance_exec, so a `def`
  # inside a context is not on the object the block runs against.
  def refused(argv_pair)
    status, out, err = run_script("--", "--as", "boss", "--pair", argv_pair, "--apply")
    assert_equal(1, status, out)
    assert_match(/fix: /, err)
    out
  end

  def matrix_post(tags, mxc: "mxc://41chan.net/#{SecureRandom.hex(8)}")
    as(@tunnel) { create(:post, uploader: @tunnel, md5: md5, tag_string: tags, source: mxc) }
  end

  def chan_post(tags)
    as(@sample) { create(:post, uploader: @sample, md5: md5, tag_string: tags, source: "https://boards.4chan.org/b/thread/#{rand(1_000_000)}") }
  end

  def hidden?(post, user)
    CreatorVisibility.forget!
    CurrentUser.scoped(user) { post.reload.hidden_from?(user) }
  end

  # Every row the merge reads or writes, so a dry run and a rerun can be
  # shown to change none of it.
  def snapshot
    [
      Post.order(:id).pluck(:id, :tag_string, :parent_id, :is_deleted, :room_ids, :fav_count, :score),
      PostMxc.order(:mxc).pluck(:mxc, :post_id, :source),
      FourierPostCreator.order(:post_id).pluck(:post_id, :mxid),
      FourierTagSource.order(:post_id, :tag).pluck(:post_id, :tag, :source, :status, :public),
      FourierGenerationMetadata.order(:md5).pluck(:md5, :raw_md5, :poster),
      Favorite.order(:post_id, :user_id).pluck(:post_id, :user_id),
      PostVote.order(:id).pluck(:post_id, :user_id, :score, :is_deleted),
      Comment.order(:id).pluck(:id, :post_id),
      Note.order(:id).pluck(:post_id, :body),
      Pool.order(:id).pluck(:id, :post_ids),
      FavoriteGroup.order(:id).pluck(:id, :post_ids),
      CreatorUserRule.order(:id).pluck(:id, :post_id),
      CreatorGalleryPost.order(:id).pluck(:id, :post_id),
      PostFlag.order(:id).pluck(:post_id, :reason),
      ModAction.count,
    ]
  end

  setup do
    CreatorPrefixes.reset!
    CreatorTagRelease.reset_cache!
    @admin = create(:admin_user, name: "boss")
    @tunnel = create(:approver_user, name: "tunnel")
    @sample = create(:approver_user, name: "sample")
    @gold = create(:gold_user)
    @maple = create(:user)
    @named = create(:user)    # a Member maple allowed onto the retired post by name
    @stranger = create(:user) # a Member nobody let in
    @fan = create(:gold_user)
    @both_fan = create(:gold_user)
    @voter = create(:gold_user)
    @commenter = create(:user)
    @gallery = CreatorGallery.create!(matrix_id: MAPLE, slug: "maple", user: @maple)

    @survivor = chan_post("#{GATED} 1girl smile")
    # secret_prompt in tag_string too, as on a post from before the tunnel kept
    # creator-only tags out of it (37270f5): it must not reach the survivor's.
    @retired = matrix_post("#{GATED} 1girl long_hair secret_prompt")
    @mxc = @retired.source
    FourierPostCreator.create!(post: @retired, mxid: MAPLE, recorded_by: @tunnel.id)
    FourierTagSource.record_partition!(@retired, { creator: %w[secret_prompt], auto: %w[1girl long_hair] }, @tunnel)
    FourierTagSource.record_partition!(@survivor, { auto: %w[1girl smile] }, @sample)
    # The record the tunnel filed when it stripped the upload: the stripped
    # md5 is the survivor's, the raw md5 the retired post's.
    FourierGenerationMetadata.create!(md5: @survivor.md5, raw_md5: @retired.md5, source: "matrix", poster: MAPLE, fields: { "png:parameters" => "a prompt" })

    Favorite.create!(post: @retired, user: @fan)
    Favorite.create!(post: @retired, user: @both_fan)
    Favorite.create!(post: @survivor, user: @both_fan)
    PostVote.create!(post: @retired, user: @voter, score: -1)
    @comment = as(@commenter) { create(:comment, post: @retired, creator: @commenter) }
    as(@admin) { create(:note, post: @retired, body: "a note on the picture") }
    @other = chan_post("1girl")
    @pool = as(@admin) { create(:pool, post_ids: [@retired.id, @other.id]) }
    @pool_with_both = as(@admin) { create(:pool, post_ids: [@survivor.id, @retired.id]) }
    @favgroup = as(@fan) { create(:favorite_group, creator: @fan, post_ids: [@retired.id]) }
    CreatorUserRule.set!(@gallery, @named, rule: "allow", by: @maple, post: @retired)
    # A Member who sees the gated picture only because its creator let them
    # in: their list takes the survivor only once the allow has moved with it.
    CreatorVisibility.forget!
    @named_favgroup = as(@named) { create(:favorite_group, creator: @named, post_ids: [@retired.id]) }
    CreatorGalleryPost.create!(creator_gallery: @gallery, post: @retired, position: 1)
    CreatorVisibility.forget!
    Danbooru.config.stubs(:gate3_matrix_posts_enforced?).returns(true)
  end

  teardown do
    CreatorPrefixes.reset!
  end

  should "refuse a missing or non-admin account, an abbreviated --apply, and a malformed pair" do
    [%w[--as nobody --pair 1:2], %w[--as tunnel --pair 1:2], %w[--as boss --pair 1:2 --ap], %w[--as boss --pair 1-2], %w[--as boss]].each do |argv|
      status, _out, err = run_script("--", *argv)
      assert_equal(2, status, argv.inspect)
      assert_match(/fix: /, err, argv.inspect)
    end
  end

  should "dry-run by default: print every move, write nothing" do
    before = snapshot
    status, out, _err = run_script("--", "--as", "boss", "--pair", "#{@retired.id}:#{@survivor.id}")

    assert_nil(status, out)
    assert_match(%r{\[1/1\] pair ##{@retired.id} -> ##{@survivor.id}}, out)
    assert_match(/tags: \+long_hair/, out)
    assert_match(/mxc #{Regexp.escape(@mxc)}: alias of ##{@survivor.id}/, out)
    assert_match(/creator: #{Regexp.escape(MAPLE)} moves/, out)
    assert_match(/favorites: 2/, out)
    assert_match(/DRY RUN/, out)
    assert_equal(before, snapshot)
  end

  context "applied" do
    setup do
      @status, @out, @err = run_script("--", "--as", "boss", "--pair", "#{@retired.id}:#{@survivor.id}", "--apply")
      @survivor.reload
      @retired.reload
    end

    should "succeed and say so" do
      assert_nil(@status, @out + @err)
      assert_match(/merged: 1/, @out)
    end

    should "re-map the Matrix image to the survivor as an alias, and keep the survivor a non-Matrix post" do
      assert_equal([[@survivor.id, PostMxc::ALIAS]], PostMxc.where(mxc: @mxc).pluck(:post_id, :source))
      assert_empty(PostMxc.where(post_id: @retired.id))
      assert_equal([MatrixViewerRooms::NOT_MATRIX], @survivor.room_ids)
    end

    should "union the tags onto the survivor through the tag edit, keeping a private tag out of tag_string" do
      assert_equal(%W[#{GATED} 1girl long_hair smile].sort, @survivor.tag_array.sort)
      assert_not_includes(@survivor.tag_array, "secret_prompt")
      assert_equal(@admin.id, @survivor.versions.last.updater_id)
      assert_equal(2, Tag.find_by_name("long_hair").post_count, "a deleted post still counts, as upstream counts it; the survivor adds one")
    end

    should "move the creator record, the tag sources and keep the generation record served on the survivor" do
      assert_equal([MAPLE], FourierPostCreator.where(post_id: @survivor.id).pluck(:mxid))
      assert_empty(FourierPostCreator.where(post_id: @retired.id))
      rows = FourierTagSource.where(post_id: @survivor.id).pluck(:tag, :public).to_h
      assert_equal({ "1girl" => true, "long_hair" => true, "smile" => true, "secret_prompt" => false }, rows)
      assert_empty(FourierTagSource.where(post_id: @retired.id))
      assert_equal(@survivor.md5, FourierGenerationMetadata.for_post(@survivor)&.md5)
    end

    should "move favorites, votes, the comment, the note, the pools, the favorite group and the creator's rows" do
      assert_equal([@fan.id, @both_fan.id].sort, Favorite.where(post_id: @survivor.id).pluck(:user_id).sort)
      assert_empty(Favorite.where(post_id: @retired.id))
      assert_equal(2, @survivor.fav_count)
      assert(PostVote.active.exists?(post_id: @survivor.id, user_id: @voter.id, score: -1))
      assert_not(PostVote.active.exists?(post_id: @retired.id))
      assert_equal(@survivor.id, @comment.reload.post_id)
      assert_equal(["a note on the picture"], Note.active.where(post_id: @survivor.id).pluck(:body))
      assert_equal([@survivor.id, @other.id], @pool.reload.post_ids)
      assert_equal([@survivor.id], @pool_with_both.reload.post_ids)
      assert_equal([@survivor.id], @favgroup.reload.post_ids)
      assert_equal([@survivor.id], @named_favgroup.reload.post_ids)
      assert_equal([@survivor.id], CreatorUserRule.where(user: @named).pluck(:post_id))
      assert_equal([@survivor.id], CreatorGalleryPost.where(creator_gallery: @gallery).pluck(:post_id))
    end

    should "keep the survivor visible to Gold and up and to whom its creator let in, and to nobody else" do
      assert_not(hidden?(@survivor, @gold))
      assert_not(hidden?(@survivor, @admin))
      assert_not(hidden?(@survivor, @named))
      assert_not(hidden?(@survivor, @maple))
      assert(hidden?(@survivor, @stranger))
    end

    should "retire the Matrix post: a deleted child of the survivor with the reason, not a jailing" do
      assert(@retired.is_deleted?)
      assert_equal(@survivor.id, @retired.parent_id)
      reason = "merged into post ##{@survivor.id}: the same picture (Matrix duplicate)"
      assert_equal(reason, @retired.flags.order(:id).last.reason)
      assert(ModAction.exists?(category: "post_delete", subject_id: @retired.id, description: "deleted post ##{@retired.id}, reason: #{reason}"))
      assert_not(@retired.jailed?)
      assert_empty(ModAction.where(category: "post_jail", subject_id: @retired.id))
      assert(@survivor.has_children?)
    end

    should "change nothing when run again, and say it is already merged" do
      before = snapshot
      status, out, _err = run_script("--", "--as", "boss", "--pair", "#{@retired.id}:#{@survivor.id}", "--apply")

      assert_nil(status, out)
      assert_match(/already merged/, out)
      assert_equal(before, snapshot)
    end
  end

  should "read pairs from a file or stdin" do
    status, out, _err = run_script("--", "--as", "boss", "--pairs-file", "-", stdin: "# retired survivor\n#{@retired.id}:#{@survivor.id}\n\n")
    assert_nil(status, out)
    assert_match(%r{\[1/1\] pair ##{@retired.id} -> ##{@survivor.id}}, out)
  end

  context "refusing a pair" do
    should "when either post is missing" do
      assert_match(/post #999999 does not exist/, refused("999999:#{@survivor.id}"))
      assert_match(/post #999999 does not exist/, refused("#{@retired.id}:999999"))
      assert_equal([@retired.id], PostMxc.where(mxc: @mxc).pluck(:post_id))
    end

    should "when the retired post has no mxc mapping" do
      assert_match(/##{@other.id} has no mxc mapping/, refused("#{@other.id}:#{@survivor.id}"))
    end

    should "when the survivor is deleted, jailed, or itself a Matrix post" do
      deleted = chan_post("1girl")
      as(@admin) { deleted.delete!("test", user: @admin) }
      assert_match(/survivor ##{deleted.id} is deleted/, refused("#{@retired.id}:#{deleted.id}"))

      jailed = chan_post("1girl troll_jail")
      as(@admin) { jailed.update!(is_deleted: true) }
      assert_match(/survivor ##{jailed.id} is (deleted|jailed)/, refused("#{@retired.id}:#{jailed.id}"))

      other_matrix = matrix_post("1girl")
      assert_match(/survivor ##{other_matrix.id} is itself a Matrix post/, refused("#{@retired.id}:#{other_matrix.id}"))
      assert_not(@retired.reload.is_deleted?)
    end

    should "when the survivor has a different recorded creator, naming both" do
      FourierPostCreator.create!(post: @survivor, mxid: "@someone:41chan.net", recorded_by: @sample.id)
      out = refused("#{@retired.id}:#{@survivor.id}")
      assert_match(/#{Regexp.escape(MAPLE)}/, out)
      assert_match(/@someone:41chan\.net/, out)
      assert_equal([@retired.id], FourierPostCreator.where(mxid: MAPLE).pluck(:post_id))
    end

    should "refuse one pair and still merge another" do
      second_survivor = chan_post("1girl")
      second_retired = matrix_post("1girl")
      status, out, _err = run_script("--", "--as", "boss", "--pair", "999999:#{@survivor.id}", "--pair", "#{second_retired.id}:#{second_survivor.id}", "--apply")

      assert_equal(1, status)
      assert_match(%r{\[2/2\]}, out)
      assert(second_retired.reload.is_deleted?)
      assert_equal(second_survivor.id, second_retired.parent_id)
    end
  end
end
