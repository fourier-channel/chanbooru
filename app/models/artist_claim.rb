# frozen_string_literal: true

# A creator's claim on a creator tag: who says it is theirs, and whether an
# admin has agreed yet.
#
# What an approved claim is FOR (design CREATOR_VISIBILITY, ruled 2026-10-07):
# it is the key to one creator's control over who sees their posts, read by
# CreatorControl. It is also the join that makes tier 5 mean anything:
# "Confirmed Creator" is a level PLUS an approved claim, and the claim turns a
# general permission into one over one artist's entry (ArtistClaim.owner?).
#
# KEYED ON THE TAG NAME. tag_name is copied from the artist when the claim is
# filed and never changes. Any unbanned member can rename an Artist; keyed on
# the row, an approved claim followed the rename onto whichever creator's tag
# the entry was renamed to. Keyed on the name, renaming moves nothing: every
# reader asks `standing` (CreatorControl, CreatorTagRelease, owner?).
#
# One trace of the row remains. The per-artist unique index
# (index_artist_claims_one_approved_per_artist) was kept, because migrations
# here are additive only, and it allows one approved claim per Artist ROW. So
# an entry renamed under an approved claim cannot take a second one under its
# new name; that claim is refused when filed and again when approved, naming
# the rename, instead of failing at the index. Retiring that index is a later
# contract migration's to do.
#
# WHAT MAY BE CLAIMED (operator ruling 2026-10-04, design Q6 2026-10-07):
#   - only a tag the LIVE creator-prefix list locks (CreatorPrefixes). An
#     unlocked tag is one any member can put on any post, so a claim on it
#     would hand its holder whatever posts somebody chose to tag;
#   - only by the gallery whose verified Matrix localpart the tag strips to:
#     <prefix>X is claimable by @X:... "only if they are identical once the
#     prefix is stripped";
#   - never under the MASTER prefix (the one whose provenance is Matrix, today
#     41chan_): "41chan_<self> needs no claim" -- CreatorControl gives it to
#     the Matrix account it names directly.
# Checked when the claim is filed and again when it is approved, against the
# list as it is at that moment. The rule is a precondition, not proof: an admin
# still decides.
#
# DECIDED BY AN ADMIN (Q6), and logged. approve!/reject! refuse anyone else and
# write an admin-only ModAction. Dual-callable: the queue and any later
# automation call the same two verbs.
class ArtistClaim < ApplicationRecord
  PENDING = "pending"
  APPROVED = "approved"
  REJECTED = "rejected"
  STATUSES = [PENDING, APPROVED, REJECTED].freeze

  belongs_to :artist
  belongs_to :creator_gallery
  belongs_to :approver, class_name: "User", optional: true

  before_validation :take_tag_name_from_artist, on: :create

  validates :status, inclusion: { in: STATUSES }
  validates :tag_name, presence: true
  validate :tag_name_unchanged
  validate :tag_is_claimable_by_gallery, on: %i[create approve]
  validate :one_approved_claim_per_tag, if: :approved_or_new?
  validate :one_approved_claim_per_artist_row, if: :approved_or_new?
  validate :one_open_claim_per_gallery, on: :create

  scope :approved, -> { where(status: APPROVED) }
  scope :pending, -> { where(status: PENDING) }
  # Claims filed by galleries linked to this booru account.
  scope :held_by, ->(user) { where(creator_gallery_id: CreatorGallery.where(user_id: user.id).select(:id)) }

  def pending? = status == PENDING
  def approved? = status == APPROVED
  def rejected? = status == REJECTED

  # The booru account behind the claim.
  #
  # Read through the gallery rather than stored again here, so there is one
  # answer to "whose is this" and it cannot come apart. The gallery's matrix_id
  # was verified by fourier-auth when the gallery was made; user_id is the
  # account linked to it under that verified session.
  def claimant = creator_gallery&.user

  # Whether this user owns this artist, right now -- for EDITING the artist
  # entry (ArtistPolicy). Not who controls posts: that is CreatorControl,
  # which never reads TagGrant.
  #
  # Deliberately a READ of two stored rows rather than anything derived from the
  # request. The verified Matrix identity arrives in a header, which no Pundit
  # policy can see and which is absent from API calls and background jobs
  # entirely -- so identity is established once, at claim time, under a verified
  # session, and every later question is answered from the database.
  def self.owner?(user, artist)
    return false if user.nil? || artist.nil? || user.is_anonymous?

    # An edit TagGrant on the artist's tag confers exactly what an approved
    # claim does -- the admin console's way of assigning "that exact set of
    # permissions over that exact tag" (operator, 2026-09-04) without walking
    # the claim flow.
    return true if TagGrant.granted?(user, [artist.name], "edit")

    # By the entry's NAME, not its row: renaming an entry moves no editing
    # rights onto another creator's tag (section 9).
    held_by(user).where(tag_name: artist.name).standing.any?
  end

  # The approved claims in this relation that still confer anything, as
  # [tag_name, creator_gallery_id] pairs: each one re-checked at use against
  # the live prefix list -- its tag still locked, the stripped-name rule still
  # holding -- never trusted from the row. Read through the VISIBILITY copy of
  # the list, which keeps the last good list when the file breaks: what a
  # creator controls must not switch off because a file broke, and the lock
  # refuses tag edits meanwhile. Every reader of a claim asks this one method
  # (CreatorControl, CreatorTagRelease, owner?), so they cannot disagree.
  def self.standing(entries = CreatorPrefixes.visibility_config[:entries])
    approved.joins(:creator_gallery).pluck(:tag_name, "creator_galleries.id", "creator_galleries.matrix_id")
            .select { |tag, _, mxid| refusal(tag, mxid, entries).nil? }
            .map { |tag, gallery_id, _| [tag, gallery_id] }
  end

  # A claim by `gallery` on `tag_name`, filed by `user`, ready to save -- with
  # a new Artist entry when the tag has none, as /artists would make one --
  # and the reason it cannot be filed, nil when it can. The one check behind
  # every "Claim" button (artist page, gallery edit page) and the filing
  # itself, so an offer never leads to a refusal.
  #
  # @return [Array(ArtistClaim, String|nil)]
  def self.prepare(gallery, user, tag_name)
    name = Artist.normalize_name(tag_name.to_s)
    artist = Artist.find_by(name: name) || Artist.new(name: name)
    claim = new(artist: artist, creator_gallery: gallery)
    if user.nil? || user.is_anonymous? || gallery&.user_id != user.id
      refusal = "Link this page to your booru account before claiming a creator tag"
    elsif user.is_banned?
      refusal = "A banned account cannot claim a creator tag"
    elsif artist.new_record? && artist.invalid?
      refusal = artist.errors.full_messages.join("; ")
    elsif claim.invalid?
      refusal = claim.errors.full_messages.join("; ")
    end
    [claim, refusal]
  end

  # The claim rule, stated once: is `tag_name` claimable by the Matrix account
  # `matrix_id` under the prefix list `entries`? nil when it is, otherwise the
  # reason it is not. CreatorControl asks it again every time a claim is used.
  def self.refusal(tag_name, matrix_id, entries = CreatorPrefixes.entries)
    name = tag_name.to_s
    entry = entries.find { |e| name.start_with?(e.prefix) && name.length > e.prefix.length }
    return "#{name} is not a locked creator tag: only a tag under a listed creator prefix can be claimed" if entry.nil?

    stripped = name.delete_prefix(entry.prefix)
    return "#{name} needs no claim: a #{entry.prefix} tag belongs to the Matrix account it names" if master?(entry)

    localpart = localpart(matrix_id)
    return nil if localpart.present? && localpart.casecmp?(stripped)

    "#{name} can only be claimed by the Matrix account @#{stripped}: a #{entry.prefix} creator tag is claimable only " \
      "when it is identical to the claimant's Matrix name once the prefix is stripped"
  end

  # The prefix whose provenance is Matrix: the master creator tag, linked to
  # the Matrix identity itself rather than to a claim.
  def self.master?(entry) = entry.provenance.casecmp?("Matrix")

  # "@maple:41chan.net" -> "maple"
  def self.localpart(matrix_id) = matrix_id.to_s[/\A@([^:]+):/, 1]

  # The decision and its log entry are one write: an approval nobody can
  # find in the mod log is the thing the log exists to rule out.
  def approve!(by:)
    transaction do
      decide!(by: by, status: APPROVED, context: :approve)
      ModAction.log("approved the claim of #{creator_gallery.matrix_id} on creator tag #{tag_name}",
                    :artist_claim_approve, subject: artist, user: by)
    end
  end

  # Also withdraws an approval: the people who approve can undo one, through
  # the same logged verb.
  def reject!(by:, note: "")
    transaction do
      decide!(by: by, status: REJECTED, note: note.to_s)
      ModAction.log("rejected the claim of #{creator_gallery.matrix_id} on creator tag #{tag_name}#{": #{note}" if note.present?}",
                    :artist_claim_reject, subject: artist, user: by)
    end
  end

  private

  def decide!(by:, status:, context: nil, **attrs)
    raise User::PrivilegeError, "Only an admin can decide a creator claim." unless by&.is_admin?

    if status == APPROVED && !pending?
      errors.add(:base, "Only a pending claim can be approved; this one is #{self.status}")
      raise ActiveRecord::RecordInvalid, self
    end

    assign_attributes(status: status, approver: by, decided_at: Time.zone.now, **attrs)
    save!(context: context)
  end

  def take_tag_name_from_artist
    self.tag_name = artist&.name if tag_name.blank?
  end

  def tag_name_unchanged
    errors.add(:tag_name, "cannot change once the claim is filed (it was #{tag_name_was})") if persisted? && tag_name_changed?
  end

  # Compared against the gallery's matrix_id, which fourier-auth verified when
  # the gallery was made -- never against anything the request says. A broken
  # prefix list refuses the claim rather than passing it.
  def tag_is_claimable_by_gallery
    reason = ArtistClaim.refusal(tag_name, creator_gallery&.matrix_id)
    errors.add(:base, reason) if reason
  rescue CreatorPrefixes::ConfigError => e
    errors.add(:base, "claims cannot be checked while the creator-prefix list is broken: #{e.message}")
  end

  def approved_or_new? = approved? || new_record?

  # Belt to the database index's braces. The index refuses the write; this
  # produces a readable error instead of a constraint violation. Also asked
  # at filing: a claim that could never be approved is not filed.
  def one_approved_claim_per_tag
    clash = ArtistClaim.approved.where(tag_name: tag_name).where.not(id: id).exists?
    errors.add(:base, "#{tag_name} already has an approved claim; if it is held wrongly, ask an admin to withdraw it first") if clash
  end

  # The same for the kept per-artist index (see the header): an entry renamed
  # under someone's approved claim still carries it. A clash on the same tag
  # is the check above's to name.
  def one_approved_claim_per_artist_row
    held = ArtistClaim.approved.where(artist_id: artist_id).where.not(id: id).where.not(tag_name: tag_name).pick(:tag_name)
    return if held.nil?

    errors.add(:base, "The artist entry now named #{artist&.name} carries the approved claim on #{held}: it was renamed " \
                      "since. Ask an admin to restore its name before claiming #{tag_name}")
  end

  # One question per gallery per tag at a time: asking again is for after a
  # refusal, never while waiting or once granted.
  def one_open_claim_per_gallery
    open = ArtistClaim.where(tag_name: tag_name, creator_gallery_id: creator_gallery_id).where.not(status: REJECTED).pick(:status)
    errors.add(:base, "A claim on #{tag_name} from this gallery is already waiting for an admin") if open == PENDING
    errors.add(:base, "#{tag_name} is already this gallery's by an approved claim") if open == APPROVED
  end
end
