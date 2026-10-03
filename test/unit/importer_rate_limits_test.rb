require "test_helper"

# The first-party importers' ceilings (fourier-sampling posts as an Approver).
# One sampled image charges posts:create and artist_commentaries:write once
# each, and its bytes charged uploads:create at ingest; the poster's spacing
# is set to run under the lowest of the two posting buckets.
class ImporterRateLimitsTest < ActiveSupport::TestCase
  context "a trusted importer" do
    setup do
      @user = create(:approver_user)
    end

    should "be allowed 120 posts a minute" do
      assert_equal 120.0 / 60, PostPolicy.new(@user, Post.new).rate_limit_for_create[:rate]
    end

    should "be allowed 120 commentary writes a minute, matching posts" do
      limit = ArtistCommentaryPolicy.new(@user, ArtistCommentary.new(post: create(:post))).rate_limit_for_write
      assert_equal ["artist_commentaries:write", 120.0 / 60], limit.values_at(:action, :rate)
    end

    should "be allowed 96 uploads a minute" do
      upload = Upload.new(uploader: @user)
      upload.stubs(:invalid?).returns(false) # the tier, not the validity check, is under test
      assert_equal 96.0 / 60, UploadPolicy.new(@user, upload).rate_limit_for_create[:rate]
    end
  end
end
