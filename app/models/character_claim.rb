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
# ENDED by the creator (release!) or by an admin (reject!, which withdraws an
# approval too). An unlinked gallery or a banned account stops the rights at
# once (standing reads the gallery's account as it is now; WikiPagePolicy
# asks unbanned?) and keeps the mark: ownership is a fact about the character.
class CharacterClaim < ApplicationRecord
  PENDING = "pending"
  APPROVED = "approved"
  REJECTED = "rejected"
  RELEASED = "released"
  STATUSES = [PENDING, APPROVED, REJECTED, RELEASED].freeze

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

  belongs_to :creator_gallery
  belongs_to :approver, class_name: "User", optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :tag_name, presence: true
  validate :tag_name_unchanged
  validate :tag_is_claimable_by_gallery, on: %i[create approve]
  validate :one_approved_claim_per_tag, if: :approved_or_new?
  validate :one_open_claim_per_gallery, on: :create

  scope :approved, -> { where(status: APPROVED) }
  scope :pending, -> { where(status: PENDING) }

  def pending? = status == PENDING
  def approved? = status == APPROVED
  def rejected? = status == REJECTED
  def released? = status == RELEASED

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

  # The claim rule, stated once: may the gallery `gallery` claim `tag_name`?
  # nil when it may, otherwise a sentence that names the fix.
  def self.refusal(tag_name, gallery, entries = CreatorPrefixes.entries)
    name = tag_name.to_s
    reason = name_refusal(name, gallery&.slug, entries)
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
      verb = approved? ? "withdrew the approval of" : "rejected"
      update!(status: REJECTED, approver: by, decided_at: Time.zone.now, note: note.to_s)
      ModAction.log("#{verb} @#{creator_gallery.slug}'s claim on original character #{tag_name}#{": #{note}" if note.present?}",
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

  private

  # The approval and everything it does, in the caller's transaction: the tag
  # as a character (checked, never assumed: upstream skips a refused re-file
  # in silence), the decision, the implication to `original`, the log entry.
  def take_effect!(approver, how)
    unless pending?
      errors.add(:base, "Only a pending claim can be approved; this one is #{status}")
      raise ActiveRecord::RecordInvalid, self
    end

    tag = Tag.find_or_create_by_name(tag_name, category: "character", current_user: approver)
    unless tag.character?
      errors.add(:base, "#{tag_name} is filed as #{tag.category_name.downcase} and could not be re-filed as a character " \
                        "by #{approver.name}: an admin re-files it, then approves again")
      raise ActiveRecord::RecordInvalid, self
    end

    assign_attributes(status: APPROVED, approver: approver, decided_at: Time.zone.now)
    save!(context: :approve)
    imply_original!(tag, approver)
    ModAction.log("approved @#{creator_gallery.slug}'s claim on original character #{tag_name}#{" #{how}" if how}",
                  :character_claim_approve, subject: tag, user: approver)
  end

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
    reason = CharacterClaim.refusal(tag_name, creator_gallery)
    errors.add(:base, reason) if reason
  rescue CreatorPrefixes::ConfigError => e
    errors.add(:base, "claims cannot be checked while the creator-prefix list is broken: #{e.message}")
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

  # One question per gallery per tag at a time.
  def one_open_claim_per_gallery
    open = CharacterClaim.where(tag_name: tag_name, creator_gallery_id: creator_gallery_id).where(status: [PENDING, APPROVED]).pick(:status)
    errors.add(:base, "A claim on #{tag_name} from this gallery is already waiting for an admin") if open == PENDING
    errors.add(:base, "#{tag_name} is already yours by an approved claim: nothing to file") if open == APPROVED
  end
end
