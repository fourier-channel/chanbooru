# frozen_string_literal: true

require "test_helper"

class FourierTagSourceTest < ActiveSupport::TestCase
  context "FourierTagSource" do
    setup do
      @post = create(:post)
      @user = create(:user)
    end

    should "map source/status to the right UI bucket" do
      assert_equal :both,    FourierTagSource.new(source: FourierTagSource::CREATOR | FourierTagSource::AUTO).bucket
      assert_equal :creator, FourierTagSource.new(source: FourierTagSource::CREATOR).bucket
      assert_equal :auto,    FourierTagSource.new(source: FourierTagSource::AUTO).bucket
      assert_equal :meta,    FourierTagSource.new(source: FourierTagSource::META).bucket
      assert_equal :pending, FourierTagSource.new(source: FourierTagSource::HUMAN, status: FourierTagSource::PENDING).bucket
    end

    should "record a provenance partition idempotently per (post, tag)" do
      FourierTagSource.record_partition!(@post, { "creator" => ["c"], "auto" => ["a"], "both" => ["b"], "meta" => ["highres"], "pending" => ["p"] }, @user)
      assert_equal 5, FourierTagSource.where(post_id: @post.id).count
      assert_equal :both, FourierTagSource.find_by(post_id: @post.id, tag: "b").bucket
      assert_equal :pending, FourierTagSource.find_by(post_id: @post.id, tag: "p").bucket

      # re-recording the same tags does not duplicate rows
      FourierTagSource.record_partition!(@post, { "creator" => ["c"] }, @user)
      assert_equal 5, FourierTagSource.where(post_id: @post.id).count
    end

    should "keep creator-only tags private and out of the public projection" do
      FourierTagSource.record_partition!(@post, { "creator" => ["secret"], "auto" => ["a"], "both" => ["b"], "meta" => ["highres"] }, @user)
      assert_equal false, FourierTagSource.find_by(post_id: @post.id, tag: "secret").public
      proj = FourierTagSource.matrix_projection(@post)
      refute_includes proj[:tags], "secret"
      assert_empty proj[:sources][:creator]
      assert_includes proj[:tags], "a"
    end

    should "surface private tags to the creator but not to anonymous viewers" do
      FourierTagSource.record_partition!(@post, { "creator" => ["secret"], "auto" => ["a"] }, @user)
      assert_includes FourierTagSource.for_viewer(@post, @user)[:creator], "secret"
      assert_empty FourierTagSource.for_viewer(@post, nil)[:creator]
      assert_includes FourierTagSource.for_viewer(@post, nil)[:auto], "a"
    end

    should "show a tag that has no provenance row instead of dropping it" do
      @post.update!(tag_string: "a troll_jail")
      FourierTagSource.record_partition!(@post, { "auto" => ["a"] }, @user)

      buckets = FourierTagSource.for_viewer(@post, @user)
      assert_includes buckets[:auto], "a"
      assert_includes buckets[:unsourced], "troll_jail"
      refute_includes buckets[:unsourced], "a"
    end

    should "not leak a private tag back through the unsourced fallback" do
      @post.update!(tag_string: "secret a")
      FourierTagSource.record_partition!(@post, { "creator" => ["secret"], "auto" => ["a"] }, @user)

      # The creator sees it, once, in the bucket that says where it came from.
      mine = FourierTagSource.for_viewer(@post, @user)
      assert_includes mine[:creator], "secret"
      refute_includes mine[:unsourced], "secret"

      # Everyone else sees it nowhere. A private tag has a row; it is simply not
      # a VISIBLE one, and that must not read as "no row, so show it".
      theirs = FourierTagSource.for_viewer(@post, nil)
      assert_empty theirs[:creator]
      refute_includes theirs[:unsourced], "secret"
      assert_empty theirs.values.flatten.grep(/secret/)
    end

    should "keep the unsourced fallback out of the public matrix projection" do
      @post.update!(tag_string: "a troll_jail")
      FourierTagSource.record_partition!(@post, { "auto" => ["a"] }, @user)

      proj = FourierTagSource.matrix_projection(@post)
      refute_includes proj[:tags], "troll_jail"
      assert_includes proj[:tags], "a"
    end
  end
end
