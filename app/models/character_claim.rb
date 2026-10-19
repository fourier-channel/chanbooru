# frozen_string_literal: true

# A creator's claim on an original character's tag: who says the character is
# theirs, and whether it stands (OC ownership, operator rulings 2026-10-11).
#
# WHAT MAY BE CLAIMED. <name>_(<slug>), where <slug> is the claiming gallery's
# own -- its verified Matrix localpart (FourierTagSource::ORIGINAL_CHARACTER,
# "<name>_(<creator>) is THE OC tag") -- so nobody claims under another
# creator's name. Never a name under a listed creator prefix (those are
# creator tags), never an invalid tag name, never a tag filed as anything but
# general or character, never an alias antecedent. Checked when filed, again
# when approved, and again at every use (`standing`).
#
# WHAT IT CONFERS, read from stored rows and never from the request, as
# ArtistClaim.owner? is: the creator's linked booru account keeps the
# character's wiki page (WikiPagePolicy: the owner and admins only, Q3), its
# category stays character unless an admin re-files it (TagPolicy), and an
# alias or implication touching it needs an admin while a move away is
# refused (BulkUpdateRequest::Command). It confers NOTHING over who sees
# posts: CreatorControl, CreatorTagRelease and ArtistPolicy never read it, and
# the tag stays one anyone may put on a post, fan art included.
#
# DECIDED (Q2): approved on filing when the name is clean -- the tag absent or
# empty, no live wiki page, no alias either way -- because the qualifier is
# the filer's verified name and a clean name takes nothing from anyone;
# otherwise an admin decides in /admin/artist_claims. On approval the tag is
# created or re-filed as a character and made to imply the copyright tag
# `original` (Q4), and both stay after a release or a withdrawal.
#
# MOVED ONTO (operator, 2026-10-12: "Many of these characters belong to other
# creators, I'll just be the first one to post them" -- the poster is not the
# creator -- and "at which point selphdestruct should be immediately assigned
# ownership"). When a tag in one of the 2026-09-19 shapes (oc_kayla) is moved
# onto <name>_(<q>) -- an alias or a rename, both TagMover, the one place that
# sees every move -- the creator named by <q> gets an approved claim at once,
# decided by the approver of the move (take_up_on_move!). Never the poster,
# never the mover. With no gallery named <q> yet the claim is HELD for that
# slug (creator_slug, no gallery) and approved, as that same approver, the
# moment such a gallery is made (take_up_held!). A target the name rule
# refuses refuses the move itself, before anything moves (move_refusal):
# a move that silently conferred nothing would break the rule.
#
# ENDED by the creator (release!) or by an admin (reject!, which withdraws an
# approval too, and a held claim before its gallery comes). An unlinked
# gallery or a banned account stops the rights at once (standing reads the
# gallery's account as it is now; WikiPagePolicy asks unbanned?) and keeps
# the mark: ownership is a fact about the character.
class CharacterClaim < ApplicationRecord
  # The quarantine's name half (NamesTags, TagQuarantine): rows naming a
  # flagged or banished tag are withheld from the viewers its name is.
  prepend NamesTags

  names_tags(->(names) { { tag_name: names } }) { |claim| [claim.tag_name] }

  PENDING = "pending"
  APPROVED = "approved"
  REJECTED = "rejected"
  RELEASED = "released"
  # Ownership a move assigned to a creator with no gallery yet: waits for the
  # gallery, not for an admin (take_up_held!).
  HELD = "held"
  STATUSES = [PENDING, APPROVED, REJECTED, RELEASED, HELD].freeze

  # Every approved claim is implied into this copyright tag (Q4).
  ORIGINAL = "original"

  # Qualifiers the booru already gives a meaning of its own, so a creator
  # whose name is one of them cannot have it read as "my character": upstream
  # makes every <x>_(cosplay) tag create <x> and add `cosplay` to its posts
  # (Tag#create_character_tag_for_cosplay_tag, Tag.automatic_tags_for), adds
  # `meme` for <x>_(meme), and TagMover carries <x>_(cosplay) and an artist's
  # <x>_(style) along whenever <x> is aliased or renamed -- which would move a
  # claimed character without any check on the claim.
  RESERVED_QUALIFIERS = %w[cosplay meme style].freeze

  # One approved claim as its readers need it: the claim, its tag, and the
  # gallery behind it.
  Standing = Data.define(:id, :tag_name, :gallery_id, :slug, :title, :user_id)

  # Absent only while HELD for creator_slug (or withdrawn while held): the
  # database's check constraint says so too.
  belongs_to :creator_gallery, optional: true
  belongs_to :approver, class_name: "User", optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :tag_name, presence: true
  validates :creator_gallery, presence: true, unless: -> { held? || (rejected? && creator_slug.present?) }
  validates :creator_slug, presence: true, if: :held?
  validates :creator_gallery, absence: true, if: :held?
  validate :tag_name_unchanged
  validate :tag_is_claimable_by_gallery, on: %i[create approve]
  validate :one_approved_claim_per_tag, if: :approved_or_new?
  validate :one_open_claim_per_gallery, on: :create, unless: :held?
  validate :one_held_claim_per_tag, if: :held?

  scope :approved, -> { where(status: APPROVED) }
  scope :pending, -> { where(status: PENDING) }
  scope :held, -> { where(status: HELD) }

  def pending? = status == PENDING
  def approved? = status == APPROVED
  def rejected? = status == REJECTED
  def released? = status == RELEASED
  def held? = status == HELD

  # The creator this claim is for: its gallery's slug, or the slug it is held
  # for while there is no gallery yet.
  def slug = creator_gallery&.slug || creator_slug

  # A claim by `gallery` on `input`, filed by `user`, ready to file, and the
  # reason it cannot be, nil when it can. A bare name is completed with the
  # gallery's own slug ("maple" -> "maple_(saber)"). The one check behind the
  # edit page's form and the filing itself, so they cannot disagree.
  #
  # @return [Array(CharacterClaim, String|nil)]
  def self.prepare(gallery, user, input)
    name = Tag.normalize_name(input)
    name = "#{name}_(#{gallery&.slug})" unless name.end_with?(")")
    claim = new(creator_gallery: gallery, tag_name: name)
    if user.nil? || user.is_anonymous? || gallery&.user_id != user.id
      refusal = "Link this page to your booru account before claiming an original character"
    elsif user.is_banned?
      refusal = "A banned account cannot claim an original character"
    elsif claim.invalid?
      refusal = claim.errors.full_messages.join("; ")
    end
    [claim, refusal]
  end

  # The claim rule, stated once: may the creator `slug` (a gallery's, or the
  # one a claim is held for) claim `tag_name`? nil when it may, otherwise a
  # sentence that names the fix.
  def self.refusal(tag_name, slug, entries = CreatorPrefixes.entries)
    name = tag_name.to_s
    reason = name_refusal(name, slug, entries)
    return reason if reason

    probe = Tag.new(name: name)
    return "#{name} is not a valid tag name: #{probe.errors.full_messages.join("; ")}" if probe.invalid?(:name)

    tag = Tag.find_by_name(name)
    if tag && !(tag.general? || tag.character?)
      return "#{name} is filed as #{tag.category_name.downcase}: ask an admin to re-file it as a character first"
    end

    target = TagAlias.active.where(antecedent_name: name).pick(:consequent_name)
    "#{name} is aliased to #{target}: claim #{target}, or ask an admin to remove the alias" if target
  end

  # The part of the rule that needs no database: the shape, the creator's own
  # name in brackets, not a qualifier the booru reserves, and no creator
  # prefix. `standing` asks it again at every use, against the list as it is
  # then; FourierTagSource asks it at post time, where the fix is to name the
  # character (`fix: "name it"`) rather than to claim it.
  def self.name_refusal(name, slug, entries, fix: "claim")
    fix_as = (fix == "claim") ? "claim it as" : fix
    match = FourierTagSource::ORIGINAL_CHARACTER.match(name)
    base = match ? match[1] : name.sub(/_?\(.*\z/, "").delete("()").presence || "<name>"
    wanted = "#{base}_(#{slug})"
    return "#{name} is not an original character's tag: #{fix_as} #{wanted}, your name in brackets" if match.nil?
    return "#{name} names #{match[2]}: #{fix} #{wanted}" unless slug.present? && match[2].casecmp?(slug)

    if RESERVED_QUALIFIERS.include?(match[2].downcase)
      return "#{name} cannot be an original character's tag: the booru gives every tag ending _(#{match[2].downcase}) a meaning of its own " \
             "(it adds tags to its posts, or moves it along whenever #{base} is renamed). Ask an admin to file the character by hand"
    end

    entry = entries.find { |e| name.start_with?(e.prefix) }
    "#{entry.prefix} marks creator tags, not characters: #{fix} #{base.delete_prefix(entry.prefix)}_(#{slug})" if entry
  end

  # The approved claims in this relation that still stand, re-checked at
  # use: the gallery's name rule against the live prefix list, and no active
  # alias moving the tag away. One query. Read through the VISIBILITY copy of
  # the list, which keeps the last good list when the file breaks, so a
  # broken file never switches a creator's wiki off. Every reader asks this.
  #
  # @return [Array<Standing>]
  def self.standing(entries = CreatorPrefixes.visibility_config[:entries])
    aliased = TagAlias.active.where("tag_aliases.antecedent_name = character_claims.tag_name")
    approved.joins(:creator_gallery).where.not(aliased.arel.exists)
            .pluck(:id, :tag_name, "creator_galleries.id", "creator_galleries.slug", "creator_galleries.title", "creator_galleries.user_id")
            .map { |row| Standing.new(*row) }
            .select { |claim| name_refusal(claim.tag_name, claim.slug, entries).nil? }
  end

  # Standing claims on these names, [] without a query for names no claim
  # could have.
  def self.standing_on(names)
    names = Array(names).grep(FourierTagSource::ORIGINAL_CHARACTER)
    names.empty? ? [] : where(tag_name: names).standing
  end

  # Is any of these names a standing claim?
  def self.claimed?(names) = standing_on(names).any?

  # Whose these character tags are, as `viewer` may be told: tag => { name:,
  # href: }. A member gets the gallery's title (or @slug) and its page. A
  # signed-out visitor gets the @slug, already in the tag's name, linked only
  # to a gallery the front page promotes -- the one gallery they can open
  # (MembersOnly :anonymous_promoted_gallery). One query, and one more for a
  # signed-out visitor when a claim was found.
  def self.owners(names, viewer)
    claims = standing_on(names)
    return {} if claims.empty?

    open = MembersOnly.member?(viewer) ? nil : CreatorGallery.landing_promoted.where(id: claims.map(&:gallery_id)).pluck(:id)
    claims.to_h do |claim|
      href = Routes.creator_gallery_path(claim.slug) if open.nil? || open.include?(claim.gallery_id)
      [claim.tag_name, { name: open.nil? ? claim.title.presence || "@#{claim.slug}" : "@#{claim.slug}", href: href }]
    end
  end

  # File this claim, approving it at once when its name is clean (Q2).
  #
  # @return [Array<String>] why it waits for an admin; [] when it was approved
  def file!
    transaction do
      save!
      waits = history
      next waits if waits.any?

      begin
        transaction(requires_new: true) { take_effect!(User.system, "automatically: the name was unused (no posts, no wiki page, no alias)") }
        []
      rescue ActiveRecord::RecordInvalid => e
        # Said, not swallowed: the claim waits, and the answer names why.
        why = e.record.errors.full_messages.join("; ")
        reload
        ["it could not be approved automatically: #{why}"]
      end
    end
  end

  # What the name already carries, each a reason an admin should look first;
  # [] for a clean name. Its post count includes deleted posts.
  def history
    tag = Tag.find_by_name(tag_name)
    [
      ("it is on #{tag.post_count} #{"post".pluralize(tag.post_count)}" if tag&.post_count.to_i.positive?),
      ("it has a wiki page" if WikiPage.titled(tag_name).exists?(is_deleted: false)),
      *TagAlias.active.where(consequent_name: tag_name).pluck(:antecedent_name).map { |from| "#{from} is aliased to it" },
    ].compact
  end

  def approve!(by:)
    raise User::PrivilegeError, "Only an admin can decide an original character claim." unless by&.is_admin?

    transaction { take_effect!(by, nil) }
  end

  # Also withdraws an approval.
  def reject!(by:, note: "")
    raise User::PrivilegeError, "Only an admin can decide an original character claim." unless by&.is_admin?

    transaction do
      what = { APPROVED => "withdrew the approval of @#{slug}'s claim", HELD => "withdrew @#{slug}'s held claim" }.fetch(status, "rejected @#{slug}'s claim")
      update!(status: REJECTED, approver: by, decided_at: Time.zone.now, note: note.to_s)
      ModAction.log("#{what} on original character #{tag_name}#{": #{note}" if note.present?}",
                    :character_claim_reject, subject: Tag.find_by_name(tag_name), user: by)
    end
  end

  # The creator gives the character up: their own linked, unbanned account
  # only. The tag, its wiki page and its implication stay.
  def release!(by:)
    unless by.present? && !by.is_banned? && creator_gallery.user_id == by.id
      raise User::PrivilegeError, "Only the creator who holds this claim can release it."
    end

    unless approved?
      errors.add(:base, "Only an approved claim can be released; this one is #{status}")
      raise ActiveRecord::RecordInvalid, self
    end

    transaction do
      update!(status: RELEASED, decided_at: Time.zone.now)
      ModAction.log("@#{creator_gallery.slug} released their claim on original character #{tag_name}",
                    :character_claim_release, subject: Tag.find_by_name(tag_name), user: by)
    end
  end

  # A tag move from `old_name` to `new_name` that assigns ownership: the slug
  # of the creator who gets it, nil for any other move. Only a move FROM one
  # of the 2026-09-19 shapes (FourierTagSource.legacy_original_character)
  # ONTO <base>_(<q>) assigns anything, and what it assigns is <q>'s.
  def self.move_owner(old_name, new_name)
    return nil unless FourierTagSource.legacy_original_character(old_name.to_s)

    FourierTagSource::ORIGINAL_CHARACTER.match(new_name.to_s)&.[](2)
  end

  # Why the move `old_name` -> `new_name` cannot assign its ownership, nil when
  # it can or assigns none. The claim rule for <q> (a creator's name, not a
  # series' -- a copyright tag with no creator page of that name -- no
  # creator prefix, no qualifier the booru reserves, a tag that can be a
  # character), read for the tag as the move will leave it: TagMover gives
  # an absent or general target the old tag's category. Asked by a bulk
  # update request when it is filed and approved, by TagMover before it moves
  # anything, and by the mapping script before it writes.
  def self.move_refusal(old_name, new_name)
    slug = move_owner(old_name, new_name)
    return nil if slug.nil?

    why = "#{slug} is not a creator's name (a Matrix localpart): move #{old_name} onto <name>_(<the creator's Matrix name>)" unless slug.match?(CreatorGallery::SLUG)
    # <q> naming a series (hilda_(pokemon)) is not a creator: a hold for it
    # would make a canon character original, owned by whoever registers that
    # name. A creator page of that name says it is a creator after all.
    if why.nil? && Tag.exists?(name: slug, category: TagCategory::COPYRIGHT) && !CreatorGallery.exists?(slug: slug)
      why = "#{slug} is a copyright tag (a series), not a creator with a page, so #{new_name} is that series' character and no one's original one: " \
            "to fold #{old_name} into it, use mass update #{old_name} -> #{new_name} (moves its posts, gives no ownership); " \
            "if #{slug} really is a creator's Matrix name, make their creator page first"
    end
    why ||= refusal(new_name, slug)
    old = Tag.find_by_name(old_name)
    target = Tag.find_by_name(new_name)
    if why.nil? && old && !(old.general? || old.character?) && (target.nil? || target.general?)
      why = "#{old_name} is filed as #{old.category_name.downcase}, which the move would give #{new_name}: an admin re-files #{old_name} as a character first"
    end
    "#{old_name} -> #{new_name}: #{why}" if why
  rescue CreatorPrefixes::ConfigError => e
    # Fork: words only. What is wrong with the list (a path on the server,
    # an errno, the parser's words, the fix's command) goes to the log: this
    # sentence reaches a bulk update request's refusal, which a bot relays
    # into a room (technetium-81, 2026-10-19).
    Rails.logger.error("move #{old_name} -> #{new_name}: ownership not checked, the creator-prefix list is broken: #{e.message}")
    "#{old_name} -> #{new_name}: its ownership cannot be checked while the creator-prefix list is broken; the server log says what is wrong. " \
      "The site owner fixes the list, then move it again"
  end

  # Raised by TagMover, before anything moves, for a move whose ownership the
  # claim rule refuses (move_refusal).
  class MoveRefused < StandardError; end

  # Assign the ownership the move `old_name` -> `new_name` confers, as
  # `approver`, the approver of the move; nothing for a move that confers none.
  # Called by TagMover once the move is done, after move_refusal passed.
  #
  #   <q>'s claim already stands, or is held         nothing (:stands, :held)
  #   <q> has a gallery                              its pending claim, or a new one, approved (:approved)
  #   <q> has none yet                               a claim HELD for <q>, the tag a character implying
  #                                                  `original` now; approved when the gallery comes (:held_now)
  #
  # @return [Symbol, nil]
  def self.take_up_on_move!(old_name, new_name, approver)
    slug = move_owner(old_name, new_name)
    return nil if slug.nil?

    move = "on the move of #{old_name} -> #{new_name} approved by #{approver.name}"
    gallery = CreatorGallery.find_by(slug: slug)
    transaction do
      if gallery.nil?
        next :held if held.exists?(tag_name: new_name)

        claim = create!(tag_name: new_name, creator_slug: slug, status: HELD, approver: approver, note: "held for @#{slug} #{move}")
        tag = claim.establish_character!(approver)
        ModAction.log("held @#{slug}'s claim on original character #{new_name} #{move}, until a creator gallery named #{slug} exists",
                      :character_claim_hold, subject: tag, user: approver)
        next :held_now
      end
      next :stands if where(creator_gallery: gallery).standing_on([new_name]).any?

      claim = pending.find_by(tag_name: new_name, creator_gallery: gallery) || create!(creator_gallery: gallery, tag_name: new_name)
      claim.take_effect!(approver, move)
      :approved
    end
  end

  # A gallery named `gallery.slug` now exists: every claim held for that slug
  # is its, approved as the approver of the move that assigned it. One that
  # can no longer be approved (the tag re-filed, aliased away, the prefix list
  # changed) is left PENDING on the gallery for an admin, its note saying why,
  # and warned about -- never a reason to refuse the gallery.
  def self.take_up_held!(gallery)
    held.where(creator_slug: gallery.slug).find_each do |claim|
      claim.update!(status: PENDING, creator_gallery: gallery)
      begin
        transaction(requires_new: true) { claim.take_effect!(claim.approver || User.system, claim.note) }
      rescue ActiveRecord::RecordInvalid => e
        why = e.record.errors.full_messages.join("; ")
        claim.reload.update!(note: "#{claim.note}; could not be approved automatically when @#{gallery.slug}'s gallery was made: #{why}")
        Rails.logger.warn("[character-claim] held claim on #{claim.tag_name} for @#{gallery.slug} left pending for an admin: #{why}")
      end
    end
  end

  # The approval and everything it does, in the caller's transaction: the tag
  # as a character implying `original` (establish_character!), the decision,
  # the log entry.
  def take_effect!(approver, how)
    unless pending?
      errors.add(:base, "Only a pending claim can be approved; this one is #{status}")
      raise ActiveRecord::RecordInvalid, self
    end

    tag = establish_character!(approver)
    assign_attributes(status: APPROVED, approver: approver, decided_at: Time.zone.now)
    save!(context: :approve)
    ModAction.log("approved @#{slug}'s claim on original character #{tag_name}#{" #{how}" if how}",
                  :character_claim_approve, subject: tag, user: approver)
  end

  # The tag as a character (checked, never assumed: upstream skips a refused
  # re-file in silence), implying `original`.
  #
  # @return [Tag]
  def establish_character!(approver)
    tag = Tag.find_or_create_by_name(tag_name, category: "character", current_user: approver)
    unless tag.character?
      errors.add(:base, "#{tag_name} is filed as #{tag.category_name.downcase} and could not be re-filed as a character " \
                        "by #{approver.name}: an admin re-files it, then approves again")
      raise ActiveRecord::RecordInvalid, self
    end

    imply_original!(tag, approver)
    tag
  end

  private

  # `original` is made a copyright tag first, and put back to copyright after:
  # upstream gives an EMPTY umbrella tag the category of the tag implying it
  # (TagImplication#process!). A tag already implying it, directly or through
  # another, is left as it is.
  def imply_original!(tag, approver)
    return if tag.implies?(ORIGINAL)

    # An existing `original` is never re-filed as a side effect of approving
    # somebody's character: one filed otherwise refuses, naming the fix.
    original = Tag.find_by_name(ORIGINAL) || Tag.find_or_create_by_name(ORIGINAL, category: "copyright", current_user: approver)
    unless original.copyright?
      errors.add(:base, "#{ORIGINAL} is filed as #{original.category_name.downcase}, not copyright: run " \
                        "script/fourier_original_characters.rb --apply (it files it as copyright), then approve again")
      raise ActiveRecord::RecordInvalid, self
    end

    TagImplication.approve!(antecedent_name: tag_name, consequent_name: ORIGINAL, approver: approver)
    original.reload
    original.update!(category: Tag.categories.copyright, updater: approver) unless original.copyright?
  end

  def tag_name_unchanged
    errors.add(:tag_name, "cannot change once the claim is filed (it was #{tag_name_was})") if persisted? && tag_name_changed?
  end

  # A broken prefix list refuses the claim rather than passing it.
  def tag_is_claimable_by_gallery
    reason = CharacterClaim.refusal(tag_name, slug)
    errors.add(:base, reason) if reason
  rescue CreatorPrefixes::ConfigError => e
    # Fork: words only, as move_refusal: this reaches a bulk update
    # request's run record (TagMover takes a claim up on a move), which
    # every reader sees.
    Rails.logger.error("claim of #{tag_name}: not checked, the creator-prefix list is broken: #{e.message}")
    errors.add(:base, "claims cannot be checked while the creator-prefix list is broken; the server log says what is wrong. The site owner fixes the list, then try again")
  end

  def approved_or_new? = approved? || new_record?

  # Belt to the unique index's braces: a readable error, not a constraint
  # violation. Also asked at filing: a claim that could never be approved is
  # not filed.
  def one_approved_claim_per_tag
    clash = CharacterClaim.approved.where(tag_name: tag_name).where.not(id: id)
    # The gallery's own approval is one_open_claim_per_gallery's to say.
    clash = clash.where.not(creator_gallery_id: creator_gallery_id) if new_record?
    clash = clash.exists?
    errors.add(:base, "#{tag_name} already has an approved claim; if it is held wrongly, ask an admin to withdraw it first") if clash
  end

  # One held claim per tag, as one approved claim per tag.
  def one_held_claim_per_tag
    errors.add(:base, "#{tag_name} is already held for @#{slug}") if CharacterClaim.held.where(tag_name: tag_name).where.not(id: id).exists?
  end

  # One question per gallery per tag at a time.
  def one_open_claim_per_gallery
    open = CharacterClaim.where(tag_name: tag_name, creator_gallery_id: creator_gallery_id).where(status: [PENDING, APPROVED]).pick(:status)
    errors.add(:base, "A claim on #{tag_name} from this gallery is already waiting for an admin") if open == PENDING
    errors.add(:base, "#{tag_name} is already yours by an approved claim: nothing to file") if open == APPROVED
  end
end
