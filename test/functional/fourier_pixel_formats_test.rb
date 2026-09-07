# frozen_string_literal: true

require "test_helper"

# Upstream refuses any pixel format outside yuv420p / yuvj420p / gbrp, because
# "neither 10-bit nor 4:4:4 are supported by Firefox" -- commit 6e685cdd4,
# 2022-10-28, written against a population of eight files and never revisited.
#
# Both halves of that claim were measured on 2026-09-07 and both have expired.
# Six VP9 formats were encoded from one synthetic source -- 1px alternating
# saturated stripes, the pattern chroma subsampling is least able to hide from
# -- and played in Firefox 128 and Chromium 128. All six decoded and painted a
# real frame in both engines: yuv420p (control), yuv444p, yuv422p, yuv420p10le,
# yuv444p10le, yuv422p10le.
#
# The run carried two deliberately corrupted files as a check on the CHECK, and
# they changed the conclusion's basis: Chromium raised PIPELINE_ERROR_DECODE on
# both, but Firefox did not error at all -- it conceals decode corruption and
# reports readyState 4. So "no MediaError in Firefox" is not evidence a file
# decoded. What separates them is the painted frame: real decodes land at 5-50
# distinct colours, the corrupt ones at 1080 and 5000.
#
# Danbooru.config.extra_video_pix_fmts is EMPTY under Rails.env.test?, so
# upstream's media_file_webm_test keeps asserting is_supported? == false for
# this very file. That makes this the only place the fork's rule is proven, and
# it proves both halves: that a measured format is accepted when configured, and
# that an UNMEASURED one stays refused.
class FourierPixelFormatsTest < ActiveSupport::TestCase
  TEN_BIT_VP9 = "test/files/webm/test-yuv420p10le-vp9.webm"

  # The production list, as measured. Kept here so a change to the config has to
  # be a deliberate change to this test too.
  MEASURED = %w[yuv420p10le yuv444p yuv444p10le yuv422p yuv422p10le].freeze

  context "a 10-bit VP9 webm" do
    should "be refused with upstream's allowlist" do
      Danbooru.config.stubs(:extra_video_pix_fmts).returns([])
      assert_equal(false, MediaFile.open(TEN_BIT_VP9).is_supported?)
    end

    should "be accepted once the format is allowed" do
      Danbooru.config.stubs(:extra_video_pix_fmts).returns(MEASURED)
      file = MediaFile.open(TEN_BIT_VP9)
      assert_equal("yuv420p10le", file.pix_fmt)
      assert_equal(true, file.is_supported?)
    end
  end

  context "every format measured on 2026-09-07" do
    should "be accepted, and refused again with upstream's allowlist" do
      MEASURED.each do |fmt|
        Danbooru.config.stubs(:extra_video_pix_fmts).returns(MEASURED)
        file = MediaFile.open(TEN_BIT_VP9)
        file.stubs(:pix_fmt).returns(fmt)
        assert_equal(true, file.is_supported?, "#{fmt} should be accepted")

        # The same file with upstream's list must go the other way, or the
        # assertion above is not measuring the allowlist at all.
        Danbooru.config.stubs(:extra_video_pix_fmts).returns([])
        bare = MediaFile.open(TEN_BIT_VP9)
        bare.stubs(:pix_fmt).returns(fmt)
        assert_equal(false, bare.is_supported?, "#{fmt} should be refused by upstream")
      end
    end
  end

  context "a real 4:4:4 file from the test corpus" do
    # Stubbed pix_fmt proves the allowlist branch; this proves it against actual
    # bytes, which is the assertion that would survive the stub being wrong.
    FOUR_FOUR_FOUR = "test/files/mp4/test-300x300-yuv444p-h264.mp4"

    should "report 4:4:4 and be refused with upstream's allowlist" do
      Danbooru.config.stubs(:extra_video_pix_fmts).returns([])
      file = MediaFile.open(FOUR_FOUR_FOUR)
      assert_equal("yuv444p", file.pix_fmt)
      assert_equal(false, file.is_supported?)
    end

    should "be accepted once 4:4:4 is allowed" do
      Danbooru.config.stubs(:extra_video_pix_fmts).returns(MEASURED)
      assert_equal(true, MediaFile.open(FOUR_FOUR_FOUR).is_supported?)
    end
  end

  context "a format nobody measured" do
    should "stay refused, because widening one format is not evidence about another" do
      # yuv440p is banned by the same upstream line and sits right beside the
      # formats that were tested. Relaxing it on the strength of its neighbours
      # is the over-generalisation this test exists to prevent.
      Danbooru.config.stubs(:extra_video_pix_fmts).returns(MEASURED)
      file = MediaFile.open(TEN_BIT_VP9)
      file.stubs(:pix_fmt).returns("yuv440p")
      assert_equal(false, file.is_supported?)
    end
  end

  context "the production configuration" do
    should "allow exactly the measured formats and nothing else" do
      # Guards the switch itself: if the predicate stopped being consulted,
      # every assertion above would still pass with the list hardcoded.
      Danbooru.config.unstub(:extra_video_pix_fmts)
      Rails.env.stubs(:test?).returns(false)
      assert_equal(MEASURED, Danbooru.config.extra_video_pix_fmts)
    end

    should "be empty under test, so upstream's suite still measures upstream" do
      Danbooru.config.unstub(:extra_video_pix_fmts)
      assert_equal([], Danbooru.config.extra_video_pix_fmts)
    end
  end
end
