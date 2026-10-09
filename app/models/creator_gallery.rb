# frozen_string_literal: true

# A creator's individualized presentation page: a curated selection of their
# posts, blog-style messages, and a Matrix contact link. Keyed by a Matrix
# identity (MXID); write access is gated to that identity or an admin (see
# CreatorGalleriesController + FourierIdentity).
class CreatorGallery < ApplicationRecord
  STYLES = %w[grid masonry filmstrip spotlight].freeze

  belongs_to :user, optional: true
  has_many :creator_gallery_posts, -> { order(:position, :id) }, dependent: :destroy, inverse_of: :creator_gallery
  has_many :posts, through: :creator_gallery_posts
  has_many :creator_gallery_messages, -> { order(created_at: :desc) }, dependent: :destroy, inverse_of: :creator_gallery
  # Claims are history (who asked, who decided), so a gallery that has filed
  # one is not deleted out from under it.
  has_many :artist_claims, dependent: :restrict_with_error
  # The creator's visibility panel (CREATOR_VISIBILITY sections 4-5). The
  # database cascades these away with the gallery; nothing else depends on
  # them.
  has_many :creator_groups, dependent: nil

  # Who sees this creator's posts when a post says nothing of its own: public
  # (whoever the site already lets see it), groups (members of the groups in
  # its audience) or private (the creator and the users they name, never a
  # group: Q9). What each means is
  # CreatorVisibility's to decide.
  #
  # NULL until the creator chooses, decided as public -- but kept apart from
  # a chosen public, because Q7 (2026-10-07) opens a creator's Matrix-posted
  # image on the booru only on THEIR allow, "public" among them. Once chosen,
  # it cannot be unset again.
  AUDIENCES = %w[public groups private].freeze

  validates :slug, presence: true, uniqueness: true, format: { with: %r{\A[a-z0-9._=\-/]+\z} }
  validates :matrix_id, presence: true, uniqueness: true
  validates :style, inclusion: { in: STYLES }
  validates :title, length: { maximum: 120 }
  validates :bio, length: { maximum: 4000 }
  validates :default_audience, inclusion: { in: AUDIENCES }, unless: -> { default_audience.nil? && !default_audience_changed? }

  # Landing-page promotion. Timestamps, not flags: promoted wants an order, and
  # "creator of the month" wants history -- setting this month's feature must
  # not erase who it was last month.
  # `id: :desc` is a TIE-BREAK, not decoration. Two galleries promoted in the
  # same request share a promoted_at to the microsecond, and an unstable sort
  # then reorders the front page between one render and the next for no reason
  # a reader could name.
  scope :promoted, -> { where.not(promoted_at: nil).order(promoted_at: :desc, id: :desc) }

  # HOW MANY THE LANDING PAGE TAKES, stated once.
  #
  # It used to be stated twice and the two disagreed. LandingShowcase took
  # `promoted.limit(6)` flat; LandingController took `promoted`, removed the
  # current feature, THEN limited to 6. So the carousel row and the card row
  # beneath it could draw from different sets of galleries -- off by one
  # whenever a gallery was both featured and promoted, which is a state the
  # admin console will make ordinary.
  #
  # The exclusion is gone rather than copied to the other caller. Its stated
  # reason was that the feature "is shown in its own section, so it does not
  # also appear in the row underneath it", and that section no longer exists --
  # the operator superseded it on 2026-09-17. Nothing writes featured_at
  # either, so the exclusion has never once removed a gallery in production.
  LANDING_LIMIT = 6

  def self.landing_promoted(limit = LANDING_LIMIT)
    promoted.limit(limit)
  end

  # The current feature is simply the most recently featured one. No cron job,
  # no month arithmetic, nothing to expire: setting a new feature is the whole
  # act, and until someone does, last month's stands rather than the page
  # showing an empty slot.
  # PARKED, 2026-09-17, and deliberately not deleted.
  #
  # featured_at backed "Creator of the month", a single gallery in its own
  # section on the landing page. That section is gone: the idea became the
  # plural "Featured Creators" carousel row, which is configured by ARTIST TAGS
  # on the landing console and does not read this column.
  #
  # It is kept for the expansion the operator named -- pinning a GALLERY to
  # that row rather than a tag -- which is what this column already models.
  # NOTHING READS IT TODAY and nothing ever wrote it; if that expansion is
  # dropped, drop the column with it rather than leaving a plausible name
  # attached to nothing, which is exactly what made it cost an afternoon to
  # work out the difference between this and promoted_at.
  def self.current_feature
    where.not(featured_at: nil).order(featured_at: :desc).first
  end

  before_validation :default_contact
  after_create :close_groups_named_for_me

  # URL key is the slug (Matrix localpart), not the numeric id.
  def to_param = slug

  # The MXID a visitor should message; falls back to the owning identity.
  def contact = matrix_contact.presence || matrix_id

  # Who may set this creator's panel -- default, overrides, groups, members,
  # allows and blocks: the booru account linked to the gallery (set from a
  # verified Matrix match, CreatorGalleriesController) or an admin. Never a
  # moderator: moderators see nothing a creator hid (Q2). A banned account
  # writes nothing here, as it writes nothing anywhere (ApplicationPolicy).
  def managed_by?(user)
    return false if user.nil? || user.is_anonymous? || user.is_banned?

    user.is_admin? || (user_id.present? && user.id == user_id)
  end

  # An audience in the creator panel's words (2026-10-09): what the panel,
  # its notices and the post page's "who sees this" all say.
  #
  # @param group_labels [Array<String>] CreatorGroup.label of each group, so
  #   a tier group says every higher tier sees it too (Q3), as enforced
  def self.audience_words(audience, group_labels)
    case audience
    when "public" then "Everyone#{" (plus #{group_labels.to_sentence})" if group_labels.any?}"
    when "groups" then group_labels.any? ? "Members of #{group_labels.to_sentence}" : "Members of my groups, with no group listed"
    when "private" then "Private"
    else "Not chosen yet (acts as Everyone)"
    end
  end

  # The creator default and the groups it includes, in one logged write.
  #
  # @return [Array<String>, nil] the names of the groups now in it; nil when
  #   it already was exactly this (nothing written, nothing logged)
  def set_default_audience!(audience, by:, group_ids: [])
    raise User::PrivilegeError, "Only this creator or an admin can set who sees their posts." unless managed_by?(by)

    ids = CreatorAudienceGroup.refuse!(audience, group_ids)
    transaction do
      next nil if default_audience == audience && CreatorAudienceGroup.current_ids(self, nil) == ids.sort

      update!(default_audience: audience)
      names = CreatorAudienceGroup.replace!(self, nil, audience, group_ids)
      ModAction.log("set the default audience of creator #{matrix_id} to #{audience}#{" (groups: #{names.join(", ")})" if names.any?}",
                    :creator_audience_update, subject: self, user: by)
      names
    end
  end

  private

  # A group another creator made in this creator's name before the booru
  # knew them (CreatorGroup: the gap the site-wide name index leaves; second
  # repair, 2026-10-09). Closed to requests, so visitors are not drawn to ask
  # the wrong creator, and logged for an admin to settle: dissolving it is
  # the admin's call, through its maker's panel, not a page's side effect.
  # matrix_id is set once, at creation, so this is the one moment to ask.
  def close_groups_named_for_me
    tag = CreatorControl.master_tags(matrix_id).first
    return if tag.nil?

    like = "#{CreatorGroup.sanitize_sql_like(tag)}\\_%"
    named = CreatorGroup.where.not(creator_gallery_id: id).where("name = ? OR name LIKE ?", tag, like).includes(:creator_gallery)
    named.select(&:reads_as_another_creator?).each do |group|
      group.update!(open_to_requests: false)
      ModAction.log("closed creator group #{group.name} to requests: its name reads as creator #{matrix_id}'s, whose page was just made. " \
                    "An admin settles whose it is (dissolve it from #{group.creator_gallery.matrix_id}'s panel, or leave it)",
                    :creator_group_update, subject: group.creator_gallery, user: User.system)
    end
  end

  def default_contact
    self.matrix_contact = matrix_id if matrix_contact.blank?
  end
end
