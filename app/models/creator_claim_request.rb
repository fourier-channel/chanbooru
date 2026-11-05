# frozen_string_literal: true

# One creator's request for the creator names that are not theirs by their
# Matrix name alone (operator, 2026-11-05): the names they found in the
# Claim Pool's search, filed together with one note, for an admin to decide.
#
# FILED ONLY through `file!`, the Claim Pool's one action. Each name it is
# given comes out one of three ways, and `judge` says which before anything
# is saved, so the pool's labels and the filing cannot disagree:
#   - IMMEDIATE: a direct match of the page's verified Matrix name, approved
#     as it is filed (ArtistClaim#file_direct!) and never part of a request;
#   - REQUESTED: any other name a claim could be filed on, filed by review
#     (ArtistClaim by_review) under this request, for an admin;
#   - REFUSED: with the reason, which names what to do instead.
# A request is saved only when at least one name was REQUESTED: a filing of
# direct matches alone leaves no ticket for an admin to close.
#
# A NAME HIDDEN FROM THE FILER (CreatorPrefixes.hidden_for?) is filed
# whatever its state -- posted under or not, held by someone or not -- so the
# answer never says whether a name the filer may not see exists. The admin
# sees all of it and decides.
#
# Each claim keeps its own decision (ArtistClaim#approve!/reject!); this row
# holds what the creator said and which names they asked for at once.
class CreatorClaimRequest < ApplicationRecord
  IMMEDIATE = :immediate
  REQUESTED = :requested
  REFUSED = :refused

  # Names in one request: a creator with more than this has a conversation
  # to have with an admin, not a form to fill.
  MAX_NAMES = 20

  # Names one page may have waiting for an admin at once: past it, the
  # queue is the conversation, and the next name waits for an answer.
  MAX_WAITING = MAX_NAMES * 2

  # More names than MAX_NAMES in one filing; its message says what to do.
  class TooManyNames < ArgumentError; end

  # What became of one name: its outcome and, when refused, why.
  Result = Data.define(:name, :outcome, :reason)

  belongs_to :creator_gallery
  has_many :artist_claims, dependent: :nullify

  normalizes :note, with: ->(note) { note.to_s.strip.truncate(2000) }

  # What filing `name` for `gallery` by `user` would do, without doing it:
  # [the claim ready to save, its outcome, the refusal or nil]. The pool asks
  # it for every name it shows; `file!` asks it again for every name filed.
  #
  # @return [Array(ArtistClaim, Symbol, String|nil)]
  def self.judge(gallery, user, name)
    direct = ArtistClaim.refusal(Artist.normalize_name(name.to_s), gallery&.matrix_id).nil?
    claim, refusal = ArtistClaim.prepare(gallery, user, name, by_review: !direct)
    return [claim, REFUSED, refusal] if refusal

    if !direct && ArtistClaim.pending.where(creator_gallery: gallery, by_review: true).count >= MAX_WAITING
      return [claim, REFUSED, "#{MAX_WAITING} names wait for an admin already; send #{claim.tag_name} once some are answered"]
    end

    hidden = !direct && CreatorPrefixes.hidden_for?(claim.tag_name, user)
    unless hidden
      # Another's tag withheld from the filer (Tag#hidden_from?: quarantined,
      # restricted, only on posts a creator hid) reads as one never posted
      # under, so the answer does not say it exists. The filer's own direct
      # name is theirs to know about.
      tag = Tag.find_by(name: claim.tag_name)
      return [claim, REFUSED, "nothing is posted under #{claim.tag_name} yet: a creator name is claimed once it is on a post"] if tag.nil? || tag.post_count <= 0 || (!direct && tag.hidden_from?(user))
      return [claim, REFUSED, "#{claim.tag_name} is another creator's by an approved claim; if it is held wrongly, say so to an admin"] if !direct && ArtistClaim.approved.exists?(tag_name: claim.tag_name)
    end

    [claim, direct ? IMMEDIATE : REQUESTED, nil]
  end

  # The names the Claim Pool starts with: the page's Matrix localpart under
  # every creator prefix but the master one (4chan_maple, aichan_maple), its
  # direct-name counterparts, whether or not anything is posted under them.
  #
  # @return [Array<String>]
  def self.counterparts(gallery)
    localpart = ArtistClaim.localpart(gallery.matrix_id).to_s.downcase
    return [] if localpart.empty?

    CreatorPrefixes.entries.reject { |entry| ArtistClaim.master?(entry) }.map { |entry| "#{entry.prefix}#{localpart}" }
  end

  # The creator names `user` finds by `query`: creator tags they may see
  # (Tag.visible_to) whose name contains it, most used first. The query
  # itself comes first when it is a whole name under a creator prefix, so a
  # name hidden from the searcher can still be asked for, and a hidden name
  # reads alike whether or not it exists.
  #
  # @return [Array<String>]
  def self.search(user, query, limit: 20)
    wanted = Artist.normalize_name(query.to_s)
    return [] if wanted.length < 2

    found = Tag.visible_to(user).where(category: TagCategory::ARTIST).where("tags.name LIKE ?", "%#{sanitize_sql_like(wanted)}%")
               .order(post_count: :desc, name: :asc).limit(limit).pluck(:name)
    whole = CreatorPrefixes.entries.any? { |entry| wanted.start_with?(entry.prefix) && wanted.length > entry.prefix.length }
    whole ? [wanted, *found].uniq : found
  end

  # The Claim Pool's rows: each of `names` with what filing it would do
  # (judge), so the pool's labels and the filing cannot disagree. A name this
  # page already holds or awaits is left out: the page's claims list shows it.
  #
  # @return [Array<Result>]
  def self.pool(gallery, user, names)
    filed = gallery.artist_claims.where.not(status: ArtistClaim::REJECTED).pluck(:tag_name)
    (names.map { |name| Artist.normalize_name(name.to_s) }.compact_blank.uniq - filed).first(MAX_NAMES * 2).map do |name|
      _, outcome, reason = judge(gallery, user, name)
      Result.new(name: name, outcome: outcome, reason: reason)
    end
  end

  # File every name in `names` for `gallery`, by `user`, with one `note`.
  # Names are taken one at a time, so one refused or raced name never undoes
  # the others; each Result says what became of its name.
  #
  # @return [Array<Result>]
  def self.file!(gallery:, user:, names:, note: "")
    wanted = names.map { |name| Artist.normalize_name(name.to_s) }.compact_blank.uniq
    raise TooManyNames, "a request names at most #{MAX_NAMES} creator names; send the rest in another" if wanted.size > MAX_NAMES

    request = new(creator_gallery: gallery, note: note)
    wanted.map do |name|
      claim, outcome, refusal = judge(gallery, user, name)
      next Result.new(name: name, outcome: REFUSED, reason: refusal) if outcome == REFUSED

      transaction(requires_new: true) do
        claim.artist.save! if claim.artist.new_record?
        if outcome == IMMEDIATE
          claim.file_direct!
        else
          claim.creator_claim_request = request
          claim.save!
        end
      end
      Result.new(name: name, outcome: outcome, reason: nil)
    rescue ActiveRecord::RecordInvalid => e # a race with another filing, between the judging and the save
      Result.new(name: name, outcome: REFUSED, reason: e.record.errors.full_messages.join("; "))
    rescue ActiveRecord::RecordNotUnique
      Result.new(name: name, outcome: REFUSED, reason: "#{name} gained an approved claim meanwhile; reload to see it")
    end
  end
end
