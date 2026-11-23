# frozen_string_literal: true

require "test_helper"

# The booru's visibility push (operator 2026-11-22: "jails and sensitive tags
# should be pushes"): a save that jails, deletes or gates a post placed in
# Matrix rooms enqueues PushVisibilityJob after commit, and the push names
# those rooms and the post's mxcs to fourier-tunnel. Driven against a
# stand-in for the tunnel that records every request and answers from a queue.
class MatrixVisibilityPushTest < ActiveSupport::TestCase
  include TimedLinksHelper

  TUNNEL = "http://tunnel-door:8011"
  ROOM_A = "!alpha:41chan.net"
  ROOM_B = "!beta:41chan.net"

  def place!(post, rooms)
    ids = MatrixRoom.intern!(rooms).values_at(*rooms)
    Post.where(id: post.id).update_all(room_ids: ids) # rubocop:disable Rails/SkipsModelValidations -- as the placements feed writes it
    post.reload
  end

  def push(post, http) = MatrixVisibilityPush.new(post.id, url: TUNNEL, http: http)

  def logged
    lines = []
    DanbooruLogger.stubs(:info).with { |message, *| lines << message }
    lines
  end

  setup do
    @user = create(:user)
    @post = as(@user) { create(:post, tag_string: "landscape", source: "mxc://41chan.net/pic#{SecureRandom.hex(4)}", md5: SecureRandom.hex(16)) }
    Danbooru.config.stubs(:restricted_tags).returns(["gatedname"])
  end

  context "the push" do
    should "name the post's rooms and mxcs, and be done on 202" do
      place!(@post, [ROOM_A, ROOM_B])
      http = FakeSamplingHttp.new.answer({ queued: true, post_id: @post.id, rooms: 2 }, status: 202)

      assert_equal :pushed, push(@post, http).push!
      call = http.calls.sole
      assert_equal :post, call[:method]
      assert_equal "#{TUNNEL}/visibility/#{@post.id}", call[:url]
      assert_equal [ROOM_A, ROOM_B].sort, call[:options][:json][:rooms].sort
      assert_equal [@post.source], call[:options][:json][:mxcs]
      assert_equal [:rooms, :mxcs], call[:options][:json].keys, "no tags, rating or reason are sent"
    end

    should "ask nothing for a post in no room" do
      Post.where(id: @post.id).update_all(room_ids: [0, -1]) # rubocop:disable Rails/SkipsModelValidations
      http = FakeSamplingHttp.new
      assert_equal :no_rooms, push(@post, http).push!
      assert_empty http.calls
    end

    should "leave out an mxc the tunnel would refuse, rather than lose the whole push" do
      place!(@post, [ROOM_A])
      PostMxc.insert_all([{ post_id: @post.id, mxc: "mxc://41chan.net/bad id", source: PostMxc::ALIAS, created_at: Time.zone.now, updated_at: Time.zone.now }]) # rubocop:disable Rails/SkipsModelValidations
      http = FakeSamplingHttp.new.answer({ queued: true }, status: 202)
      push(@post, http).push!
      assert_equal [@post.source], http.calls.sole[:options][:json][:mxcs]
    end

    should "raise to be tried again when the tunnel does not answer or answers 5xx, naming the fix" do
      place!(@post, [ROOM_A])
      error = assert_raises(MatrixVisibilityPush::Unanswered) { push(@post, FakeSamplingHttp.new.answer("", status: 598)).push! }
      assert_match(/did not answer \(598\).*docker ps/, error.message)
      error = assert_raises(MatrixVisibilityPush::Unanswered) { push(@post, FakeSamplingHttp.new.answer({ error: "boom", fix: "see log" }, status: 500)).push! }
      assert_match(/answered 500.*boom/, error.message)
    end

    should "log a refusal with its fix and not raise, so it is not sent again" do
      place!(@post, [ROOM_A])
      lines = logged
      answer = { error: "rooms is missing or empty", fix: "POST /visibility/<postId> with a JSON body" }
      assert_equal :refused, push(@post, FakeSamplingHttp.new.answer(answer, status: 400)).push!
      assert_match(/refused by fourier-tunnel \(400\): rooms is missing or empty -- fix: POST.*one-minute re-read. Fix: /, lines.sole)
    end

    should "say an older tunnel has no push, and what to deploy" do
      place!(@post, [ROOM_A])
      lines = logged
      assert_equal :refused, push(@post, FakeSamplingHttp.new.answer({ error: "not found" }, status: 404)).push!
      assert_match(/deploy fourier-tunnel b8abc50 or later/, lines.sole)
    end
  end

  context "the job" do
    should "be tried again while the tunnel does not answer, and log the loss with its fix when the tries run out" do
      MatrixVisibilityPush.any_instance.expects(:push!).times(5).raises(MatrixVisibilityPush::Unanswered, "fourier-tunnel did not answer (598)")
      lines = []
      DanbooruLogger.stubs(:info).with { |message, *| lines << message if message.include?("given up") }
      perform_enqueued_jobs { PushVisibilityJob.perform_later(@post.id) }
      assert_match(/given up after 5 tries: fourier-tunnel did not answer \(598\).*PushVisibilityJob\.perform_now\(#{@post.id}\)/, lines.sole)
    end
  end

  context "a save" do
    setup { place!(@post, [ROOM_A]) }

    should "push when it deletes the post, and when it undeletes it" do
      assert_enqueued_with(job: PushVisibilityJob, args: [@post.id]) { as(@user) { @post.update!(is_deleted: true) } }
      clear_enqueued_jobs
      assert_enqueued_with(job: PushVisibilityJob, args: [@post.id]) { as(@user) { @post.reload.update!(is_deleted: false) } }
    end

    should "push when it takes a restricted tag on, and off" do
      assert_enqueued_with(job: PushVisibilityJob, args: [@post.id]) { as(@user) { @post.update!(tag_string: "landscape gatedname") } }
      clear_enqueued_jobs
      assert_enqueued_with(job: PushVisibilityJob, args: [@post.id]) { as(@user) { @post.reload.update!(tag_string: "landscape") } }
    end

    should "push when the jail tag goes on" do
      assert_enqueued_with(job: PushVisibilityJob, args: [@post.id]) { as_the_jail { as(@user) { @post.update!(tag_string: "landscape #{Danbooru.config.troll_jail_tag}") } } }
    end

    should "not push for any other tag change: that one waits for Technetium's one-minute re-read" do
      assert_no_enqueued_jobs(only: PushVisibilityJob) { as(@user) { @post.update!(tag_string: "landscape sky") } }
    end

    should "not push for a post in no Matrix room" do
      Post.where(id: @post.id).update_all(room_ids: [0]) # rubocop:disable Rails/SkipsModelValidations
      assert_no_enqueued_jobs(only: PushVisibilityJob) { as(@user) { @post.reload.update!(is_deleted: true) } }
    end

    should "not push for a save that rolled back" do
      assert_no_enqueued_jobs(only: PushVisibilityJob) do
        Post.transaction do
          as(@user) { @post.update!(is_deleted: true) }
          raise ActiveRecord::Rollback
        end
      end
    end
  end
end
