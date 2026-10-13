# frozen_string_literal: true

# FLAGGED-TAG QUARANTINE (operator rulings 2026-10-12; memory
# flagged-tags-are-a-review-quarantine). A tag out of normal circulation, in
# one of two states:
#
#   FLAGGED -- "It would function similarly to an auto-banish in that the
#   tag's entire existence should immediately disappear--but not as severe as
#   banished because the idea is to immediately flag any tag for review by
#   admins." Every post carrying the name, and the name itself, disappear for
#   everyone but:
#     - Admin level and up ("I did mean 'owner' danbooru level"), every post;
#     - the booru's system user, which jails and never serves a viewer;
#     - a posting bot (TagBanishment.pipeline?, not an admin) on its OWN
#       posts only: "they would retain the ability to interact with their own
#       posts while the surface would be shut to every other account". A bot
#       sees the NAMES everywhere: it strips and tags with them.
#   Including posts that gain the name later, at every door -- a post does not
#   hold a copy of the rule; every door derives it from tag_string. Turning
#   the flag off (Release) restores everything at once.
#
#   BANISHED -- removed from the vocabulary (TagBanishment): its posts and name
#   exist for the pipeline alone. Banish is one click from the review queue:
#   it sets the state, then BanishTagJob jails every carrier through the
#   booru's own jail (the jail panel hears through the post_jail feed).
#   UNBANISH is the jail panel's (operator ruling 2026-10-12): a banished name
#   is hidden from admins, so the booru has no surface to find one on, but
#   the panel reads the banished names in the quarantine document and takes
#   one off the list through the jail panel's door (#unbanish!). It releases
#   no jailed post: that stays the panel's per-post release.
#
# WHY A TABLE, NOT A COLUMN ON TAGS: a column would be versioned (TagVersion
# rows that differ only in it read as "an admin edited this tag, nothing
# changed" -- a public stamp that it was hidden) and serialized in
# /tags.json. Here neither can happen.
#
# FAIL CLOSED: the sets are never rescued. A request that cannot read them
# fails, and a failed request shows nothing.
class TagQuarantine < ApplicationRecord
  FLAGGED = "flagged"
  BANISHED = "banished"
  STATES = [FLAGGED, BANISHED].freeze

  # Posts per page of the quarantine document (GET
  # /fourier_jail/release.json?quarantine=1).
  DOCUMENT_PAGE_SIZE = 5000

  # A refused transition, with the reason and the way forward in the message.
  class Refused < StandardError; end

  belongs_to :tag
  belongs_to :flagged_by, class_name: "User", optional: true
  belongs_to :banished_by, class_name: "User", optional: true

  validates :state, inclusion: { in: STATES }

  # The request that changes a row must not keep the old set in its memo; a
  # later request in any container reads Postgres again anyway (the memo is
  # per request, MEMO_TTL as the backstop outside one).
  after_save { CreatorVisibility.forget! }
  after_destroy { CreatorVisibility.forget! }
  after_commit { CreatorVisibility.forget! }

  scope :flagged, -> { where(state: FLAGGED) }
  scope :banished, -> { where(state: BANISHED) }

  def flagged? = state == FLAGGED
  def banished? = state == BANISHED

  class << self
    # { flagged: Set, banished: Set } of tag names: ONE pluck per request,
    # whoever asks. NEVER rescues.
    def sets
      CreatorVisibility.memoized(:tag_quarantine_sets, nil) do
        rows = joins(:tag).pluck("tags.name", :state)
        {
          flagged: rows.filter_map { |name, state| name if state == FLAGGED }.to_set.freeze,
          banished: rows.filter_map { |name, state| name if state == BANISHED }.to_set.freeze,
        }.freeze
      end
    end

    def flagged_names = sets[:flagged]
    def banished_names = sets[:banished]

    # 12 hex of an HMAC over the sorted names, both states: the `tv` value a
    # publicly cached name surface (autocomplete, related tags) must carry to
    # be cached publicly, so a flip is a new cache key at once.
    def names_generation
      key = Rails.application.secret_key_base
      text = "f:#{flagged_names.sort.join(" ")}\nb:#{banished_names.sort.join(" ")}"
      OpenSSL::HMAC.hexdigest("SHA256", key, text).first(12)
    end

    def document_page_size = DOCUMENT_PAGE_SIZE

    # How much of the flagged set's POSTS `user` sees:
    #   :all  -- Admin level and up (Owner included), and the system user;
    #   :own  -- a posting bot that is not an admin: the posts it uploaded;
    #   :none -- everyone else, signed out included.
    def flagged_posts_visible_to(user)
      return :none if user.nil? || user.is_anonymous?
      return :all if user.is_admin? || user.name == Danbooru.config.system_user
      return :own if TagBanishment.pipeline?(user)

      :none
    end

    # Whether `user` is shown flagged NAMES: the same accounts as above, a
    # bot for every name (it strips and tags with them).
    def sees_flagged_names?(user) = flagged_posts_visible_to(user) != :none

    # The quarantined names `user` may not be shown: flagged ones below admin
    # (bots excepted), banished ones to all but the pipeline.
    def hidden_names_for(user)
      s = sets
      names = []
      names += s[:flagged].to_a if s[:flagged].any? && !sees_flagged_names?(user)
      names += s[:banished].to_a if s[:banished].any? && !TagBanishment.sees_banished_names?(user)
      names
    end

    # Whether `name` is a quarantined name hidden from `user`.
    def hidden_name?(name, user)
      name = name.to_s
      (flagged_names.include?(name) && !sees_flagged_names?(user)) ||
        (banished_names.include?(name) && !TagBanishment.sees_banished_names?(user))
    end

    # The ids of the posts the FLAGGED rule hides from `user`, for the
    # query-level exclusion (PostQuery#hidden_post_metatags): one GIN `&&`
    # pluck, once per request per viewer. Empty when nothing is flagged.
    def hidden_post_ids_for(user)
      flagged = flagged_names
      return [] if flagged.empty?

      mode = flagged_posts_visible_to(user)
      return [] if mode == :all

      CreatorVisibility.memoized(:flagged_post_ids, user) do
        posts = Post.where_array_includes_any("string_to_array(posts.tag_string, ' ')", flagged.to_a)
        posts = posts.where.not(uploader_id: user.id) if mode == :own
        posts.order(:id).pluck(:id)
      end
    end

    # Flag `tag` for review: its posts and name disappear at once for all
    # but the accounts above. Idempotent for a tag already flagged (the note
    # is kept); refused for a banished one.
    def flag!(tag, by:, note: "")
      transaction do
        row = lock.find_by(tag_id: tag.id)
        raise Refused, "#{tag.name} is already banished: a banished tag is not flagged again" if row&.banished?

        row || create!(tag: tag, state: FLAGGED, flagged_by: by, flagged_at: Time.zone.now, note: note.to_s).tap do
          ModAction.log("flagged tag [[#{tag.name}]] for review: #{note}".strip.delete_suffix(":"), :tag_flag, subject: tag, user: by)
        end
      end
    end

    # The section-1 body of GET /fourier_jail/release.json?quarantine=1:
    # every post carrying a flagged or banished name, deleted or not, in id
    # order, paged by id; the names for a pipeline reader only. Built per
    # request from GIN plucks, never cached, so never stale here.
    #
    # And every post carrying the jail tag (`jailed`), flagged or not
    # (session ruling 2026-10-12, from "jailed means deleted" and "shown
    # nowhere"): the Matrix door learns the set from here alone, and served
    # jailed Matrix media while these were left out.
    def document(reader:, after:)
      flagged = flagged_names.sort
      banished = banished_names.sort
      tags = "string_to_array(posts.tag_string, ' ')"
      flagged_rows = flagged.empty? ? [] : Post.where_array_includes_any(tags, flagged).pluck(:id, :md5, :source)
      banished_rows = banished.empty? ? [] : Post.where_array_includes_any(tags, banished).pluck(:id, :md5, :source)
      jailed_rows = Post.where_array_includes_any(tags, [Danbooru.config.troll_jail_tag]).pluck(:id, :md5, :source)
      flagged_ids = flagged_rows.to_set(&:first)
      banished_ids = banished_rows.to_set(&:first)
      jailed_ids = jailed_rows.to_set(&:first)

      posts = (flagged_rows + banished_rows + jailed_rows).uniq(&:first).sort_by(&:first).map do |id, md5, source|
        { id: id, md5: md5, mxc: source.to_s.start_with?("mxc://") ? source : nil, flagged: flagged_ids.include?(id), banished: banished_ids.include?(id), jailed: jailed_ids.include?(id) }
      end
      generation = Digest::SHA256.hexdigest({ flagged: flagged, banished: banished, posts: posts }.to_json).first(16)

      page = after.nil? ? posts : posts.drop_while { |post| post[:id] <= after.to_i }
      size = document_page_size
      names = TagBanishment.pipeline?(reader)
      {
        generation: generation,
        flagged: names ? flagged : nil,
        banished: names ? banished : nil,
        posts: page.first(size),
        next_after: (page.size > size) ? page[size - 1][:id] : nil,
      }
    end
  end

  # Back to normal: the row is deleted, and every post and the name return.
  def release!(by:, note: "")
    raise Refused, "#{tag.name} is banished: Release applies to a flagged tag only; a banished tag is unbanished from the jail panel (fourier-sampling)" if banished?

    transaction do
      destroy!
      ModAction.log("released flagged tag [[#{tag.name}]]: #{note}".strip.delete_suffix(":"), :tag_flag_release, subject: tag, user: by)
    end
  end

  # Banished, in one transaction, so its posts are withheld from everyone
  # but the pipeline at once; then every carrier is jailed by BanishTagJob
  # after the commit. The mod log row never names the tag: an admin never
  # sees a banished name.
  def banish!(by:, note: "")
    return self if banished?

    transaction do
      update!(state: BANISHED, banished_by: by, banished_at: Time.zone.now, note: [self.note, note.to_s].compact_blank.join("\n"))
      ModAction.log("banished tag ##{tag_id} from the review queue: #{note}".strip.delete_suffix(":"), :tag_banish, subject: tag, user: by)
    end
    BanishTagJob.perform_later(tag_id, by.id)
    self
  end

  # Off the banished list, back to normal (operator ruling 2026-10-12): the
  # row is deleted, so the name returns and every post carrying it that is
  # not jailed returns with it. A jailed post stays jailed -- the jail tag
  # withholds it on its own, and releasing it is the panel's per-post act.
  # Pressed in the jail panel: `by` is the jail panel's booru account, and
  # `panel_user` the panel user who pressed it, recorded in the mod log row.
  # That row names the tag, so like every quarantine row it is hidden again
  # if the tag is banished again (ModAction.visible).
  def unbanish!(by:, panel_user:, note: "")
    transaction do
      lock!
      raise Refused, "#{tag.name} is not banished: unbanish applies to a banished tag only" unless banished?

      destroy!
      ModAction.log("unbanished tag [[#{tag.name}]] from the jail panel, pressed by #{panel_user}: #{note}".strip.delete_suffix(":"), :tag_unbanish, subject: tag, user: by)
    end
  end
end
