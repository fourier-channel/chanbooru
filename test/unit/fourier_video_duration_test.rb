# frozen_string_literal: true

require "test_helper"

# Upstream caps a non-admin's video at 140 seconds, "2:20m", Twitter's own
# limit: a borrowed number, not a measured one. It guards no cost either. The
# check runs after the file has been fully analysed (ffprobe's frame count,
# the preview, is_corrupt?), so a long video has already been paid for by the
# time it is refused.
#
# What a long upload does cost was measured on 2026-11-04, in the dev
# container on vesper (4 cores), timing that same analysis per file:
#
#   140 s at 10 fps     5.9 s   252 MB peak
#   600 s at 10 fps    22.0 s   372 MB
#   300 s at 30 fps    17.6 s   327 MB
#   600 s at 30 fps    30.8 s   445 MB
#   900 s at 30 fps    46.6 s   558 MB
#  1800 s at 10 fps    64.6 s   716 MB
#
# Uploads are processed inside the request, so the ceiling that binds is
# time, not memory: the sampling uploader gives a request 30 s, Rack 65 s.
# Ten minutes at 30 fps sits at the first; the serving box has three times
# vesper's cores. So production allows 600 seconds (operator, 2026-11-04:
# "140 seconds seems rather arbitrary"), and the test environment keeps 140
# for upstream's own uploads_controller_test.
class FourierVideoDurationTest < ActiveSupport::TestCase
  VIDEO = "test/files/mp4/test-300x300.mp4"

  def video_lasting(seconds)
    MediaFile.open(VIDEO).tap { |file| file.stubs(:duration).returns(seconds) }
  end

  context "the duration limit" do
    setup do
      @member = create(:user)
    end

    should "be ten minutes in production" do
      Rails.env.stubs(:test?).returns(false)
      assert_equal(600, Danbooru.config.max_video_duration)
    end

    should "admit a member's video up to the configured limit" do
      Danbooru.config.stubs(:max_video_duration).returns(600)
      assert_nothing_raised { MediaAsset.validate_media_file!(video_lasting(344), @member) }
      assert_nothing_raised { MediaAsset.validate_media_file!(video_lasting(600), @member) }
    end

    should "refuse a member's video past the configured limit, naming it" do
      Danbooru.config.stubs(:max_video_duration).returns(600)
      error = assert_raises(MediaAsset::Error) { MediaAsset.validate_media_file!(video_lasting(601), @member) }
      assert_equal("Duration must be less than 600 seconds", error.message)
    end

    should "admit an admin's video of any length" do
      Danbooru.config.stubs(:max_video_duration).returns(600)
      assert_nothing_raised { MediaAsset.validate_media_file!(video_lasting(7200), create(:admin_user)) }
    end
  end
end
