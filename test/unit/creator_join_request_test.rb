# frozen_string_literal: true

require "test_helper"

# Asking to join a creator's group, and the answer (design CREATOR_VISIBILITY
# Q5, ruled 2026-10-07: "a user requests to join, the creator approves or
# refuses"; the creator panel, 2026-10-09). One filing path, file!, refusing
# in words that say what to do instead; withdraw by the asker while it waits;
# the decision reaches the asker by dmail, and nobody else is sent anything.
class CreatorJoinRequestTest < ActiveSupport::TestCase
  setup do
    CreatorPrefixes.reset!
    @admin = create(:admin_user)
    @maple = create(:user)
    @asker = create(:user)
    @gallery = CreatorGallery.create!(matrix_id: "@maple:41chan.net", slug: "maple", title: "Maple", user: @maple)
    @open = CreatorGroup.make!(@gallery, name: "41chan_maple_tier_1", tier: 1, by: @maple, open_to_requests: true)
    @closed = CreatorGroup.make!(@gallery, name: "41chan_maple_friends", by: @maple)
  end

  def refusal(group, user)
    error = assert_raises(ActiveRecord::RecordInvalid) { CreatorJoinRequest.file!(group, user) }
    error.record.errors.full_messages.join
  end

  context "filing" do
    should "make a waiting request, logging nothing" do
      request = CreatorJoinRequest.file!(@open, @asker, note: "  big fan  ")

      assert_equal(["pending", "big fan"], [request.status, request.note])
      assert_equal(0, ModAction.where(category: %w[creator_join_request_approve creator_join_request_reject]).count)
    end

    should "refuse each case in its own words, and file nothing" do
      unlinked = CreatorGallery.create!(matrix_id: "@pine:41chan.net", slug: "pine")
      unlinked_group = CreatorGroup.make!(unlinked, name: "41chan_pine_tier_1", tier: 1, by: @admin, open_to_requests: true)
      blocked = create(:user)
      CreatorUserRule.set!(@gallery, blocked, rule: "block", by: @maple)
      member = create(:user)
      @open.add_member!(member, by: @maple)
      waiting = create(:user)
      CreatorJoinRequest.file!(@open, waiting)
      before = CreatorJoinRequest.count

      {
        [@open, User.anonymous] => "Sign in to the booru to ask to join a creator's group.",
        [@open, @maple] => "This is your own group: you see all your posts already. Add people from your panel.",
        [unlinked_group, @asker] => "This creator has not linked a booru account yet, so nobody can answer. Ask them on Matrix.",
        [@closed, @asker] => "That group is not taking requests. The creator decides which groups people can ask to join.",
        [@open, blocked] => "This creator is not taking requests from your account.",
        [@open, member] => "You are already in 41chan_maple_tier_1.",
        [@open, waiting] => "You already asked to join 41chan_maple_tier_1 and the creator has not answered yet; you can withdraw it from their page.",
        [@open, create(:banned_user)] => "A banned account cannot ask to join a creator's group.",
      }.each do |(group, user), words|
        assert_equal(words, refusal(group, user), "#{user.name} asking #{group.name}")
      end
      assert_equal(before, CreatorJoinRequest.count)
    end

    should "refuse for a week after a refusal, then accept" do
      CreatorJoinRequest.file!(@open, @asker).reject!(by: @maple)

      travel(6.days) { assert_match(/\ARefused on .* You can ask again after /, refusal(@open, @asker)) }
      travel(8.days) { assert(CreatorJoinRequest.file!(@open, @asker).pending?) }
    end

    should "accept a member whose membership has ended" do
      @open.add_member!(@asker, by: @maple, expires_at: 1.day.from_now)

      travel(2.days) { assert(CreatorJoinRequest.file!(@open, @asker).pending?) }
    end
  end

  context "withdrawing" do
    setup do
      @request = CreatorJoinRequest.file!(@open, @asker)
    end

    should "delete the waiting request, for the asker" do
      @request.withdraw!(by: @asker)

      assert_not(CreatorJoinRequest.exists?(@request.id))
    end

    should "be refused to anyone else, the creator included" do
      [create(:user), @maple, @admin].each do |by|
        assert_raises(User::PrivilegeError) { @request.withdraw!(by: by) }
      end
      assert(@request.reload.pending?)
    end

    should "be refused once decided" do
      @request.reject!(by: @maple)

      error = assert_raises(ActiveRecord::RecordInvalid) { @request.withdraw!(by: @asker) }
      assert_equal("This request was already rejected; nothing to withdraw.", error.record.errors.full_messages.join)
      assert(CreatorJoinRequest.exists?(@request.id))
    end
  end

  # Q5's answer reaches the asker; the creator is never sent a dmail per
  # request (the navbar pill and the inbox carry those).
  context "the decision's dmail" do
    setup do
      @request = CreatorJoinRequest.file!(@open, @asker)
    end

    should "send nothing on filing" do
      assert_equal(0, Dmail.count)
    end

    should "tell the asker they are in, from the system account, with the end date" do
      @request.approve!(by: @maple, expires_at: Time.zone.parse("2030-12-31").end_of_day)

      dmail = Dmail.sole

      assert_equal([User.system, @asker, @asker], [dmail.from, dmail.to, dmail.owner])
      assert_equal("You are in 41chan_maple_tier_1", dmail.title)
      assert_match(%r{\AMaple let you into 41chan_maple_tier_1, until 2030-12-31\. Maple's page: \S+creators/maple\z}, dmail.body)
    end

    # The dmail promises no access (second repair, 2026-10-09): a block set
    # after filing beats the membership (Q8), and a block is never announced,
    # so the words are the same whether one stands or not.
    should "promise nothing and mention no block, for a requester kept out since filing" do
      CreatorUserRule.set!(@open.creator_gallery, @asker, rule: "block", by: @maple)
      @request.approve!(by: @maple)

      assert_match(%r{\AMaple let you into 41chan_maple_tier_1\. Maple's page: \S+creators/maple\z}, Dmail.sole.body)
    end

    should "say nothing changed for someone already in" do
      @open.add_member!(@asker, by: User.system, source: "automation", expires_at: 30.days.from_now)
      @request.approve!(by: @maple)

      assert_equal("You were already in 41chan_maple_tier_1; nothing changed.", Dmail.sole.body)
    end

    should "carry the refusal's note and the day they may ask again" do
      @request.reject!(by: @maple, note: "full up")

      dmail = Dmail.sole

      assert_equal("Request to join 41chan_maple_tier_1 refused", dmail.title)
      assert_match(%r{\AMaple refused your request: full up\. You can ask again after #{Time.zone.today + 7} from \S+creators/maple\z}, dmail.body)
    end
  end
end
