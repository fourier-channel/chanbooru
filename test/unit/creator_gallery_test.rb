# frozen_string_literal: true

require "test_helper"

class CreatorGalleryTest < ActiveSupport::TestCase
  context "CreatorGallery" do
    should "validate and default the Matrix contact to the owner MXID" do
      g = CreatorGallery.create!(slug: "alice", matrix_id: "@alice:41chan.net")
      assert_equal "@alice:41chan.net", g.contact
      assert_equal "alice", g.to_param
    end

    should "reject a bad style and a bad slug" do
      assert_not CreatorGallery.new(slug: "x", matrix_id: "@x:d", style: "nope").valid?
      assert_not CreatorGallery.new(slug: "Bad Slug!", matrix_id: "@x:d").valid?
    end

    should "enforce unique slug and matrix_id" do
      CreatorGallery.create!(slug: "bob", matrix_id: "@bob:41chan.net")
      dup = CreatorGallery.new(slug: "bob", matrix_id: "@other:41chan.net")
      assert_not dup.valid?
    end
  end

  context "FourierIdentity" do
    should "match case-insensitively and reject a blank/absent identity" do
      req = ActionDispatch::TestRequest.create("HTTP_X_FOURIER_IDENTITY" => "@Alice:41chan.net")
      assert FourierIdentity.matches?(req, "@alice:41chan.net")
      assert_not FourierIdentity.matches?(req, "@mallory:41chan.net")

      anon = ActionDispatch::TestRequest.create
      assert_nil FourierIdentity.current(anon)
      assert_not FourierIdentity.matches?(anon, "@alice:41chan.net")
    end
  end
end
