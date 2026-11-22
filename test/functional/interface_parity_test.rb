# frozen_string_literal: true

require "test_helper"

# Every surface the Modulation carve touches, for every kind of viewer, under
# both interfaces, compared byte for byte with what it drew on the day it was
# recorded (test/test_helpers/interface_recording_helper.rb says how the world
# is fixed and what is normalised).
#
# This test does not judge a page. It says only "this is not what it was".
# A failure names the surface and the first line that differs; whether the
# difference is a bug or the change you meant is yours to read.
class InterfaceParityTest < ActionDispatch::IntegrationTest
  include InterfaceRecordingHelper
  include TagQuarantineTestHelper

  # The login page in each state a Matrix identity can be in, plus after a
  # wrong password. Each is checked to be that state before it is drawn.
  def login_states
    identity = ->(mxid) { { "X-Fourier-Identity" => mxid } }
    state_of = ->(mxid) { MatrixAccount.new(nil, mxid).state }
    drawn = {}

    become("signed_out")
    drawn["login_no_identity"] = draw(:get, "/login")

    # available: an account the viewer made and then deleted themself is
    # held back for the browser session, so the page offers to make it.
    become("signed_out")
    get "/fourier_identity.json", headers: identity.call("@pvavail:41chan.net")
    made = User.find_by!(matrix_id: "@pvavail:41chan.net")
    post "/session/reauthenticate", headers: identity.call("@pvavail:41chan.net"), params: { session: { url: "/users/#{made.id}" }}
    delete "/users/#{made.id}", headers: identity.call("@pvavail:41chan.net")
    assert_equal(true, made.reload.is_deleted, "the available state needs the self-deleted account")
    @identity = identity.call("@pvavail:41chan.net")
    drawn["login_available"] = draw(:get, "/login")

    create(:user, name: "pvtaken")
    assert_equal("taken", state_of.call("@pvtaken:41chan.net"))
    become("signed_out")
    @identity = identity.call("@pvtaken:41chan.net")
    drawn["login_taken"] = draw(:get, "/login")

    assert_equal("invalid", state_of.call("@x=y:41chan.net"))
    become("signed_out")
    @identity = identity.call("@x=y:41chan.net")
    drawn["login_invalid"] = draw(:get, "/login")

    linked = create(:user, name: "pvlinked", matrix_id: "@pvlinked:41chan.net")
    assert_equal("linked", state_of.call(linked.matrix_id))
    become("signed_out")
    delete "/session", headers: identity.call(linked.matrix_id)
    @identity = identity.call(linked.matrix_id)
    drawn["login_linked_signed_out"] = draw(:get, "/login")

    totp = create(:user_with_2fa, name: "pvtotp", matrix_id: "@pvtotp:41chan.net")
    assert_equal("two_factor", state_of.call(totp.matrix_id))
    become("signed_out")
    @identity = identity.call(totp.matrix_id)
    drawn["login_two_factor"] = draw(:get, "/login")

    gone = create(:user, name: "pvgone", matrix_id: "@pvgone:41chan.net", password: "pvgonepass")
    UserDeletion.new(user: gone, deleter: @viewers["owner"]).delete!
    assert_equal("deleted", state_of.call(gone.matrix_id))
    become("signed_out")
    @identity = identity.call(gone.matrix_id)
    drawn["login_deleted"] = draw(:get, "/login")

    # signed in to the booru under another name, with an identity whose name
    # is free: the page offers the same-name account.
    become("member")
    @identity = identity.call("@pvfree:41chan.net")
    drawn["login_identity_while_signed_in"] = draw(:get, "/login")

    become("signed_out")
    drawn["login_failed_password"] = draw(:post, "/session", params: { session: { name: "pv_member", password: "wrong" }})
    drawn
  end

  # The chunk names every index line points at.
  def self.named_chunks
    InterfaceRecordingHelper::INDEX.glob("*/*.txt").flat_map { |index| index.readlines(chomp: true).map { |line| line.split[2] } }.to_set
  end

  # A record run writes each new body as a new chunk and leaves the one it
  # replaced, so once every worker has written its indexes, the chunks no
  # index names are deleted. Minitest runs after_run in the parent process
  # only, after the parallel workers are done: a worker pruning mid-run
  # could delete a chunk another worker wrote and has not yet indexed.
  if InterfaceRecordingHelper.recording?
    Minitest.after_run do
      named = named_chunks
      InterfaceRecordingHelper::CHUNKS.glob("*.txt").reject { |chunk| named.include?(chunk.basename(".txt").to_s) }.each(&:delete)
    end
  end

  setup { @original_config = Danbooru.config }
  teardown { leave_recorded_world! }

  should "keep no chunk that no index names" do
    skip "a record run is rewriting the store; it prunes unnamed chunks when it ends" if InterfaceRecordingHelper.recording?

    named = self.class.named_chunks
    orphans = InterfaceRecordingHelper::CHUNKS.glob("*.txt").reject { |chunk| named.include?(chunk.basename(".txt").to_s) }
    assert_empty(orphans.map { |chunk| chunk.relative_path_from(Rails.root).to_s }.sort.first(10),
                 "#{orphans.size} recorded bodies are named by no index (a record run that was stopped before it ended, or a " \
                 "chunk added by hand); fix: #{InterfaceRecordingHelper::RECORD_FIX} -- a whole record run deletes them when it ends")
  end

  InterfaceRecordingHelper::INTERFACES.each do |interface|
    InterfaceRecordingHelper::VIEWERS.each do |viewer|
      should "draw every surface for #{viewer} under #{interface} as recorded" do
        enter_recorded_world!(interface)
        become(viewer)
        drawn = interface_surfaces(viewer).transform_values { |method, path, options| draw(method, path, **options.to_h) }
        assert_matches_recording(interface, viewer, drawn)
      end
    end

    should "draw the login page in every Matrix state under #{interface} as recorded" do
      enter_recorded_world!(interface)
      assert_matches_recording(interface, "login_states", login_states)
    end
  end
end
