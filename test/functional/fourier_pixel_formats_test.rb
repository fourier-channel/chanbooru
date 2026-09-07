# frozen_string_literal: true

require "test_helper"

# Upstream refuses any pixel format outside yuv420p / yuvj420p / gbrp, because
# "neither 10-bit nor 4:4:4 are supported by Firefox" -- commit 6e685cdd4,
# 2022-10-28, written against a population of eight files and never revisited.
#
# Measured 2026-09-07 with Playwright Firefox 128, against a real 10-bit VP9
# file from this instance's own archive plus an 8-bit transcode of the same
# source as a control: no MediaError, readyState 4, 20 frames decoded, a frame
# painted to canvas with pixel spread 235. Firefox renders it, indistinguishably
# from the control. The claim was true when written and expired since.
#
# Danbooru.config.extra_video_pix_fmts is EMPTY under Rails.env.test?, so
# upstream's media_file_webm_test keeps asserting is_supported? == false for
# this very file. That makes this the only place the fork's rule is proven, so
# it proves both halves: that the format is accepted when configured, and that
# a format we have NOT measured stays refused.
class FourierPixelFormatsTest < ActiveSupport::TestCase
  TEN_BIT_VP9 = "test/files/webm/test-yuv420p10le-vp9.webm"

  context "a 10-bit VP9 webm" do
    should "be refused with upstream's allowlist" do
      Danbooru.config.stubs(:extra_video_pix_fmts).returns([])
      assert_equal(false, MediaFile.open(TEN_BIT_VP9).is_supported?)
    end

    should "be accepted once the format is allowed" do
      Danbooru.config.stubs(:extra_video_pix_fmts).returns(%w[yuv420p10le])
      file = MediaFile.open(TEN_BIT_VP9)
      assert_equal("yuv420p10le", file.pix_fmt)
      assert_equal(true, file.is_supported?)
    end
  end

  context "a format nobody measured" do
    should "stay refused, because widening one format is not evidence about another" do
      # 4:4:4 is banned by the same upstream line and was NOT tested. Relaxing
      # it on the strength of a 10-bit result is the over-generalisation this
      # test exists to prevent.
      Danbooru.config.stubs(:extra_video_pix_fmts).returns(%w[yuv420p10le])
      file = MediaFile.open(TEN_BIT_VP9)
      file.stubs(:pix_fmt).returns("yuv444p")
      assert_equal(false, file.is_supported?)
    end
  end

  context "the production configuration" do
    should "allow 10-bit and nothing else beyond upstream" do
      # Guards the switch itself: if the predicate stopped being consulted,
      # every assertion above would still pass with the list hardcoded.
      Danbooru.config.unstub(:extra_video_pix_fmts)
      Rails.env.stubs(:test?).returns(false)
      assert_equal(%w[yuv420p10le], Danbooru.config.extra_video_pix_fmts)
    end
  end
end
