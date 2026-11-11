# frozen_string_literal: true

require "test_helper"

# A MATRIX IMAGE FOLLOWS ITS POST, IN ITS ROOMS TOO (operator, 2026-11-11):
# "a sensitive image showing up for a moment and then visibly popping out of
# existence". fourier-auth asks, for a room member, which posts holding the
# image the booru hides from them (MediaDoorAsk.hidden_from_reader) and
# refuses the image when one is hidden; Technetium pops the message.
class MediaDoorMatrixReaderTest < ActionDispatch::IntegrationTest
  setup do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    Danbooru.config.stubs(:anonymous_default_deny?).returns(true)
    Danbooru.config.stubs(:gate3_matrix_posts_enforced?).returns(true)
    Danbooru.config.stubs(:deleted_post_visibility_level).returns(User::Levels::ADMIN) # production's; the test env shows them to all
    Danbooru.config.stubs(:fourier_media_door).returns("fourier-auth")
    Resolv.stubs(:getaddresses).with("fourier-auth").returns(["127.0.0.1"])
    MediaDoorAsk.instance_variable_set(:@door_addresses, nil) # its lookup is kept between requests

    @tunnel = create(:contributor_user)
    @member = create(:user, matrix_id: "@member:41chan.net")
    @gold = create(:gold_user, matrix_id: "@gold:41chan.net")
    @plain, @gated, @deleted = as(@tunnel) do
      [
        create(:post, uploader: @tunnel, md5: SecureRandom.hex(16), tag_string: "rain"),
        create(:post, uploader: @tunnel, md5: SecureRandom.hex(16), tag_string: "rain child"),
        create(:post, uploader: @tunnel, md5: SecureRandom.hex(16), tag_string: "rain"),
      ]
    end
    # Rooms the readers are not in: the rooms are not this ask's question.
    [@plain, @gated, @deleted].each { |post| post.update_columns(room_ids: ["!elsewhere:41chan.net"]) } # rubocop:disable Rails/SkipsModelValidations -- PostMxc's answer
    @deleted.update_columns(is_deleted: true) # rubocop:disable Rails/SkipsModelValidations -- the state, not how it is reached
  end

  def ask(md5s, matrix_id:, media_door: "matrix_reader")
    get posts_path(format: :json), params: { tags: "md5:#{md5s.join(",")}", only: "is_deleted,md5,source", limit: md5s.size, media_door: media_door, matrix_id: matrix_id }
    assert_response :success, response.body.first(400)
    response.parsed_body
  end

  def hidden(rows)
    rows.to_h { |row| [row["md5"], row["hidden"]] }
  end

  def all_md5s
    [@plain, @gated, @deleted].map(&:md5)
  end

  should "hide a gated or deleted post from a member, whatever the rooms" do
    assert_equal({ @plain.md5 => false, @gated.md5 => true, @deleted.md5 => true }, hidden(ask(all_md5s, matrix_id: "@member:41chan.net")))
  end

  should "not hide a gated post from a Gold reader" do
    assert_equal({ @plain.md5 => false, @gated.md5 => false, @deleted.md5 => true }, hidden(ask(all_md5s, matrix_id: "@gold:41chan.net")))
  end

  should "read the Matrix id case-blind, as the account was linked" do
    assert_equal({ @gated.md5 => false }, hidden(ask([@gated.md5], matrix_id: "@Gold:41chan.net")))
  end

  should "answer a reader with no booru account as a stranger, and make none" do
    assert_no_difference("User.count") do
      assert_equal({ @plain.md5 => false, @gated.md5 => true, @deleted.md5 => true }, hidden(ask(all_md5s, matrix_id: "@nobody:41chan.net")))
    end
    assert_nil(session[:user_id], "the ask signed someone in")
  end

  should "answer a reader whose account was deleted as a stranger" do
    @gold.update_columns(is_deleted: true) # rubocop:disable Rails/SkipsModelValidations -- the state, not how it is reached
    assert_equal({ @gated.md5 => true }, hidden(ask([@gated.md5], matrix_id: "@gold:41chan.net")))
  end

  should "leave out an md5 no post holds, so the rooms alone decide it" do
    assert_equal({ @plain.md5 => false }, hidden(ask([@plain.md5, SecureRandom.hex(16)], matrix_id: "@member:41chan.net")))
  end

  should "not be honoured from a peer that is not the media door" do
    Resolv.stubs(:getaddresses).with("fourier-auth").returns(["10.9.9.9"])
    rows = ask(all_md5s, matrix_id: "@gold:41chan.net")
    assert(rows.none? { |row| row.key?("hidden") }, "a peer that is not the door was answered the in-room ask: #{rows.inspect}")
  end

  should "not be honoured for a matrix_id that is not one" do
    rows = ask(all_md5s, matrix_id: "gold")
    assert(rows.none? { |row| row.key?("hidden") }, "an ask with no Matrix id was answered the in-room ask: #{rows.inspect}")
  end

  should "refuse an ask that is not about md5s" do
    Danbooru.config.stubs(:anonymous_default_deny?).returns(false) # past the members-only gate, which refuses it first
    get posts_path(format: :json), params: { tags: "rain", media_door: "matrix_reader", matrix_id: "@gold:41chan.net" }
    assert_response 400
  end
end
