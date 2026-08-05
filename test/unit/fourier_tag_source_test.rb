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
  end
end
