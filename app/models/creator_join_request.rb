# frozen_string_literal: true

# A request to join a creator's group (design CREATOR_VISIBILITY Q5, ruled
# 2026-10-07: "a user requests to join, the creator approves or refuses").
#
# FILED ONLY through `file!` (the creator panel, 2026-10-09): a signed-in,
# unbanned account that is not the creator, into a group the creator OPENED
# to requests, of a creator with a linked account who can answer, not kept
# out by a creator-wide block, not already a member, with no request of
# theirs waiting, and not refused for that group in the last COOLDOWN. Each
# refusal says why and what to do instead (errors carry their own remedy,
# 2026-09-14). Filing writes no ModAction: the row is the record of who
# asked and when.
#
# Approving adds the member through CreatorGroup#add_member! -- the creator's
# own manual add, with source "request" -- so there is one way into a group
# however the decision was reached. Refusing keeps the row (who asked, who
# refused, why); the user may ask again once the cooldown is over. One open
# request per user and group at a time (a partial unique index backs that).
# Withdrawing a waiting request deletes it: nothing was decided, so there is
# nothing to keep.
#
# The requester hears the decision by dmail, after commit; the creator is
# never sent one per request (a popular creator would be spammed) -- the
# navbar's Requests pill and the panel's inbox carry it instead.
class CreatorJoinRequest < ApplicationRecord
  PENDING = "pending"
  APPROVED = "approved"
  REJECTED = "rejected"
  STATUSES = [PENDING, APPROVED, REJECTED].freeze

  # How long a refusal stands before the same person may ask the same group
  # again: it keeps a refused requester from filling the creator's inbox.
  COOLDOWN = 7.days

  belongs_to :creator_group
  # Required, but by `may_be_filed`, whose words say what to do about it.
  belongs_to :user, optional: true
  belongs_to :decided_by, class_name: "User", optional: true

  normalizes :note, with: ->(note) { note.to_s.strip.truncate(500) }

  validates :status, inclusion: { in: STATUSES }
  validate :may_be_filed, on: :create

  after_commit :tell_the_requester, on: :update, if: -> { saved_change_to_status? && !pending? }

  scope :pending, -> { where(status: PENDING) }

  # The one filing path. Raises ActiveRecord::RecordInvalid with the refusal.
  def self.file!(group, user, note: "")
    create!(creator_group: group, user: user, note: note)
  end

  def pending? = status == PENDING

  # After approve!: the membership the requester already held, which was
  # kept as it was (with its own end), or nil when approving added them.
  # The panel's notice says which, so it never claims a date not applied.
  def kept_membership = @kept

  # The day the requester may ask again after this refusal.
  def ask_again_on = (decided_at + COOLDOWN).to_date

  # A refusal still inside its COOLDOWN: the requester is told when they may
  # ask again, and may not yet.
  def refusal_standing? = status == REJECTED && decided_at > COOLDOWN.ago

  # A request filed before the user joined some other way (automation, say,
  # with an expiry) is approved WITHOUT touching that membership: re-adding
  # would replace its expiry, and a lapsed subscription would never end
  # access (section 5). The log says which happened, and that an expiry
  # given with the approval was not applied.
  #
  # @param expires_at [Time, nil] when the membership this adds ends
  def approve!(by:, expires_at: nil)
    transaction do
      decide!(by: by, status: APPROVED)
      @kept = CreatorGroupMembership.active.find_by(creator_group_id: creator_group_id, user_id: user_id)
      creator_group.add_member!(user, by: by, source: CreatorGroupMembership::REQUEST, expires_at: expires_at) unless @kept
      if @kept
        kept = " (already a member#{", until #{@kept.expires_at.utc.iso8601}" if @kept.expires_at}; membership unchanged" \
               "#{"; the expiry given was not applied" if expires_at})"
      end
      ModAction.log("approved user ##{user_id}'s request to join creator group #{creator_group.name}#{kept}",
                    :creator_join_request_approve, subject: creator_group.creator_gallery, user: by)
      self
    end
  end

  def reject!(by:, note: "")
    transaction do
      decide!(by: by, status: REJECTED, note: note)
      ModAction.log("refused user ##{user_id}'s request to join creator group #{creator_group.name}#{": #{self.note}" if self.note.present?}",
                    :creator_join_request_reject, subject: creator_group.creator_gallery, user: by)
      self
    end
  end

  # The requester takes back a request still waiting. Deleted, not marked:
  # nothing was decided. Not logged, as filing is not.
  def withdraw!(by:)
    raise User::PrivilegeError, "Only the person who asked can withdraw a request to join." unless by.present? && by.id == user_id

    with_lock do
      unless pending?
        errors.add(:base, "This request was already #{status}; nothing to withdraw.")
        raise ActiveRecord::RecordInvalid, self
      end

      destroy!
    end
  end

  private

  # Under a row lock, so two decisions at once (a double click, an admin and
  # the creator) make one membership and one log entry; the second is told.
  def decide!(by:, status:, **attrs)
    raise User::PrivilegeError, "Only this creator or an admin can decide a request to join their group." unless creator_group.creator_gallery.managed_by?(by)

    lock!
    unless pending?
      errors.add(:base, "This request was already #{self.status}.")
      raise ActiveRecord::RecordInvalid, self
    end

    update!(status: status, decided_by: by, decided_at: Time.zone.now, **attrs)
  end

  def may_be_filed
    refusal = filing_refusal
    errors.add(:base, refusal) if refusal
  end

  # The first refusal that applies, in words that say what to do instead --
  # one at a time, so the asker reads one reason, not a pile.
  def filing_refusal
    gallery = creator_group&.creator_gallery
    return "Sign in to the booru to ask to join a creator's group." if user.nil? || user.is_anonymous?
    return "A banned account cannot ask to join a creator's group." if user.is_banned?
    return "That group is not taking requests. The creator decides which groups people can ask to join." if gallery.nil? || !creator_group.open_to_requests
    return "This is your own group: you see all your posts already. Add people from your panel." if gallery.user_id == user.id
    return "This creator has not linked a booru account yet, so nobody can answer. Ask them on Matrix." if gallery.user_id.nil?
    return "This creator is not taking requests from your account." if CreatorUserRule.exists?(creator_gallery: gallery, user: user, post_id: nil, rule: CreatorUserRule::BLOCK)
    return "You are already in #{creator_group.name}." if CreatorGroupMembership.active.exists?(creator_group: creator_group, user: user)

    mine = CreatorJoinRequest.where(creator_group: creator_group, user: user)
    return "You already asked to join #{creator_group.name} and the creator has not answered yet; you can withdraw it from their page." if mine.pending.exists?

    refused = mine.where(status: REJECTED, decided_at: (Time.zone.now - COOLDOWN)..).order(decided_at: :desc).first
    "Refused on #{refused.decided_at.to_date}. You can ask again after #{refused.ask_again_on}." if refused
  end

  # The requester's answer, by dmail from the system account, once the
  # decision is committed. Nothing else in the panel notifies anyone; a block
  # never does. So an approval promises no access: a block set after filing
  # beats the membership (Q8), and words that changed with it would announce
  # it (second repair, 2026-10-09).
  def tell_the_requester
    gallery = creator_group.creator_gallery
    creator = gallery.title.presence || gallery.slug
    page = Routes.creator_gallery_url(gallery)
    if status == APPROVED && @kept
      title = "You are in #{creator_group.name}"
      body = "You were already in #{creator_group.name}; nothing changed."
    elsif status == APPROVED
      membership = CreatorGroupMembership.find_by(creator_group_id: creator_group_id, user_id: user_id)
      title = "You are in #{creator_group.name}"
      body = "#{creator} let you into #{creator_group.name}#{", until #{membership.expires_at.to_date}" if membership&.expires_at}. #{creator}'s page: #{page}"
    else
      title = "Request to join #{creator_group.name} refused"
      body = "#{creator} refused your request#{": #{note}" if note.present?}. You can ask again after #{ask_again_on} from #{page}"
    end
    dmail = Dmail.create_automated(to: user, title: title, body: body)
    Rails.logger.error("[creator_join_request] the decision dmail to user ##{user_id} was not sent: #{dmail.errors.full_messages.join("; ")}") if dmail.errors.any?
  end
end
