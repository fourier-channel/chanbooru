# frozen_string_literal: true

require "test_helper"

class CreatorGalleriesControllerTest < ActionDispatch::IntegrationTest
  context "The creator galleries controller" do
    setup do
      @gallery = CreatorGallery.create!(slug: "alice", matrix_id: "@alice:41chan.net", title: "Alice")
    end

    should "show a gallery publicly" do
      get creator_gallery_path(@gallery)
      assert_response :success
    end

    # The security-critical gate: writes are locked to the page's Matrix identity.
    should "forbid editing without a fourier identity" do
      get edit_creator_gallery_path(@gallery)
      assert_response :forbidden
    end

    should "allow editing with the matching fourier identity" do
      get edit_creator_gallery_path(@gallery), headers: { "X-Fourier-Identity" => "@alice:41chan.net" }
      assert_response :success
    end

    should "forbid editing with a different fourier identity" do
      get edit_creator_gallery_path(@gallery), headers: { "X-Fourier-Identity" => "@mallory:41chan.net" }
      assert_response :forbidden
    end
  end
end
