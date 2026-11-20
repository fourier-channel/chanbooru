# frozen_string_literal: true

class Post < ApplicationRecord
  class RevertError < StandardError; end
  class DeletionError < StandardError; end

  # The maximum number of tags a post can have.
  MAX_TAG_COUNT = 1250

  # The maximum number of new tags that can be created by a single user. Default is 20 tags per minute.
  MAX_NEW_TAGS = 20
  MAX_NEW_TAGS_INTERVAL = 1.minute

  # The maximum number of tags that can be added or removed by a user per minute. Default is 100 tags per minute.
  # Builders and the uploader aren't subject to this restriction.
  MAX_CHANGED_TAGS = 100
  MAX_CHANGED_TAGS_INTERVAL = 1.minute

  # The maximum number of levels in a parent-child hierarchy. By default, a parent-child hierarchy can be no more than 4
  # levels deep. That is, a post can have children, grandchildren, and great-grandchildren, but no great-great-grandchildren.
  MAX_PARENT_DEPTH = 4

  # The maximum number of child posts that a parent post may have.
  MAX_CHILD_POSTS = 30

  # Tags to copy when copying notes.
  NOTE_COPY_TAGS = %w[translated partially_translated check_translation translation_request reverse_translation
                      annotated partially_annotated check_annotation annotation_request]

  # The tags the booru derives from a post's own file and source
  # (#add_automatic_tags; the list is upstream's). Fork: named, so
  # script/fourier_merge_matrix_duplicates.rb leaves them to each post.
  AUTOMATIC_TAGS = %w[incredibly_absurdres absurdres highres lowres flash video ugoira animated_gif animated_png exif_rotation non-repeating_animation non-web_source wide_image tall_image].freeze

  # Post#give_favorites_to_parent's refusal: the same words for a post with
  # no parent and one whose parent is hidden from the mover.
  NO_PARENT_FOR_FAVORITES = "This post has no parent you can move its favorites to; delete it without 'Move favorites to parent'."

  # Each name escaped, so a restricted name shaped like foo_(bar) matches
  # itself rather than mismatching or raising at class load.

  RATINGS = {
    g: "General",
    s: "Sensitive",
    q: "Questionable",
    e: "Explicit",
  }.with_indifferent_access

  RATING_ALIASES = {
    safe: ["s"],
    nsfw: ["q", "e"],
    sfw: ["g", "s"],
  }.with_indifferent_access

  deletable
  has_bit_flags %w[has_embedded_notes _unused_has_cropped is_taken_down]

  normalizes :source, with: ->(source) { Post.normalize_source(source) }, apply_to_nil: true
  before_validation :merge_old_changes
  before_validation :apply_pre_metatags
  before_validation :validate_new_tags
  before_validation :normalize_tags
  validate :uploader_is_not_limited, on: :create
  validate :post_is_not_allowed, on: :create
  validate :forget_parent_the_editor_cannot_write
  validate :validate_no_parent_cycles
  validate :validate_parent_depth
  validate :validate_child_count
  validate :validate_changed_tags
  validate :validate_creator_prefixed_tags
  validate :validate_flagged_tags
  validate :validate_jail_tag_change
  validate :validate_tag_count
  validates :md5, uniqueness: { message: ->(post, _data) { "Duplicate of post ##{Post.find_by_md5(post.md5).id}" }}, on: :create
  validates :rating, presence: { message: "not selected" }
  validates :rating, inclusion: { in: RATINGS.keys, message: "must be #{RATINGS.keys.map(&:upcase).to_sentence(last_word_connector: ", or ")}" }, if: -> { rating.present? }
  validates :source, length: { maximum: 1200 }
  validates :parent, presence: { message: "post does not exist" }, if: -> { parent_id.present? && parent_id_changed? }
  before_save :parse_pixiv_id
  before_save :added_tags_are_valid
  before_save :removed_tags_are_valid
  before_save :has_artist_tag
  before_save :has_copyright_tag
  before_save :has_enough_tags
  before_save :update_tag_post_counts
  before_save :update_tag_category_counts
  before_save :note_banished_tags_gained # fork: the booru's own jail, see jail_on_banished_tags
  before_save :note_jailing_entered # fork: every booru-side jailing reaches the jail panel, see report_jailing_entered
  before_create :remove_blank_artist_commentary
  before_create :autoban
  before_create :start_matrix_post_closed # fork: gate 3 for posts, see record_post_mxc
  after_create :record_post_mxc # fork: gate 3 for posts
  after_save :create_version
  after_save :update_parent_on_save
  after_save :apply_post_metatags
  after_save :report_jailing_entered
  after_save :note_jail_state_change # fork: boo.122 D3, see Post.untagged_jailed_ids
  after_save :jail_on_banished_tags # fork: LAST, because it saves again (see create_version)
  after_create_commit :update_iqdb
  after_commit :announce_jail_state_change # fork: boo.122 D3
  after_rollback :forget_jail_state_change # fork: boo.122 D3

  belongs_to :approver, class_name: "User", optional: true
  belongs_to :uploader, class_name: "User", counter_cache: "post_upload_count"
  belongs_to :parent, class_name: "Post", optional: true, autosave: true
  has_one :media_asset, -> { active }, foreign_key: :md5, primary_key: :md5, inverse_of: :post
  has_one :media_metadata, through: :media_asset
  has_one :artist_commentary, dependent: :destroy
  has_one :vote_by_current_user, -> { active.where(user_id: CurrentUser.id) }, class_name: "PostVote" # XXX using current user here is wrong
  has_many :flags, class_name: "PostFlag", dependent: :destroy
  has_many :appeals, class_name: "PostAppeal", dependent: :destroy
  has_many :votes, class_name: "PostVote", dependent: :destroy
  has_many :notes, dependent: :destroy
  has_many :comments, dependent: :destroy
  has_many :children, -> { order("posts.id") }, class_name: "Post", foreign_key: "parent_id"
  has_many :approvals, class_name: "PostApproval", dependent: :destroy
  has_many :disapprovals, class_name: "PostDisapproval", dependent: :destroy
  has_many :favorites, dependent: :destroy
  has_many :replacements, class_name: "PostReplacement", dependent: :destroy
  has_many :ai_tags, through: :media_asset
  has_many :events, class_name: "PostEvent"
  has_many :mod_actions, as: :subject, dependent: :destroy
  has_many :reactions, as: :model, dependent: :destroy, class_name: "Reaction"
  has_many :dtext_links, -> { embedded_post }, foreign_key: :link_target
  has_many :embedding_wiki_pages, through: :dtext_links, source: :model, source_type: "WikiPage"

  attr_accessor :old_tag_string, :old_parent_id, :old_source, :old_rating, :post_edit

  scope :pending, -> { where(is_pending: true) }
  scope :flagged, -> { where(is_flagged: true) }
  scope :banned, -> { where(is_banned: true) }
  # XXX conflict with deletable
  scope :active, -> { where(is_pending: false, is_deleted: false, is_flagged: false) }
  scope :approved, -> { where(is_pending: false, is_deleted: false) }
  scope :appealed, -> { where(id: PostAppeal.pending.select(:post_id)) }
  scope :in_modqueue, -> { where_union_all(pending, flagged, appealed) }
  scope :expired, -> { pending.where(created_at: ...Danbooru.config.moderation_period.ago) }

  scope :unflagged, -> { where(is_flagged: false) }
  scope :has_notes, -> { where.not(last_noted_at: nil) }
  scope :for_user, ->(user_id) { where(uploader_id: user_id) }

  if PostVersion.enabled?
    has_many :versions, -> { Rails.env.test? ? order("post_versions.updated_at ASC, post_versions.id ASC") : order("post_versions.updated_at ASC") }, class_name: "PostVersion", dependent: :destroy
  end

  def self.new_from_upload(upload_media_asset, tag_string: nil, rating: nil, parent_id: nil, source: nil, artist_commentary: {}, is_pending: nil, add_artist_tag: false)
    upload = upload_media_asset.upload
    media_asset = upload_media_asset.media_asset

    # XXX depends on CurrentUser
    commentary = ArtistCommentary.new(**artist_commentary)

    if add_artist_tag
      tag_string = "#{tag_string} #{upload_media_asset.source_extractor&.artists.to_a.map(&:tag).map(&:name).join(" ")}".strip
      tag_string += " " if tag_string.present?
    end

    Post.new(
      uploader: upload.uploader,
      md5: media_asset&.md5,
      file_ext: media_asset&.file_ext,
      file_size: media_asset&.file_size,
      image_width: media_asset&.image_width,
      image_height: media_asset&.image_height,
      source: source.to_s,
      tag_string: tag_string,
      rating: rating,
      parent_id: parent_id,
      is_pending: !upload.uploader.is_contributor? || is_pending.to_s.truthy?,
      artist_commentary: commentary,
    )
  end

  concerning :FileMethods do
    def seo_tags
      presenter.humanized_essential_tag_string.gsub(/[^a-z0-9]+/, "_").gsub(/(?:^_+)|(?:_+$)/, "").gsub(/_{2,}/, "_")
    end

    def file(type = :original)
      media_asset.variant(type).open_file!
    end

    def tagged_file_url(tagged_filenames: !CurrentUser.user.disable_tagged_filenames?)
      slug = seo_tags if tagged_filenames
      media_asset.variant(:original).file_url(slug)
    end

    def tagged_large_file_url(tagged_filenames: !CurrentUser.user.disable_tagged_filenames?)
      slug = seo_tags if tagged_filenames

      if media_asset.has_variant?(:sample)
        media_asset.variant(:sample).file_url(slug)
      else
        media_asset.variant(:original).file_url(slug)
      end
    end

    def file_url
      media_asset.variant(:original).file_url
    end

    def large_file_url
      if media_asset.has_variant?(:sample)
        media_asset.variant(:sample).file_url
      else
        media_asset.variant(:original).file_url
      end
    end

    def preview_file_url
      # XXX hack to return placeholder thumbnail for Flash files the /posts.json API.
      return Danbooru.config.storage_manager.file_url("/images/flash-preview.png") if media_asset.is_flash?
      media_asset.variant(:"180x180").file_url
    end

    def file_url_for(user)
      if user.default_image_size == "large" && image_width > Danbooru.config.large_image_width
        tagged_large_file_url
      else
        tagged_file_url
      end
    end

    def is_image?
      file_ext.in?(%w[jpg gif png webp avif])
    end

    def is_flash?
      file_ext =~ /swf/i
    end

    def is_video?
      file_ext.in?(%w[webm mp4])
    end

    def is_ugoira?
      file_ext =~ /zip/i
    end

    def has_preview?
      is_image? || is_video? || is_ugoira?
    end
  end

  concerning :ImageMethods do
    def has_large?
      return false if has_tag?("animated_gif") || has_tag?("animated_png")
      return true if is_ugoira?
      is_image? && image_width.present? && image_width > Danbooru.config.large_image_width
    end

    alias_method :has_large, :has_large?

    def large_image_width
      if has_large?
        [Danbooru.config.large_image_width, image_width.to_i].min
      else
        image_width.to_i
      end
    end

    def large_image_height
      ratio = Danbooru.config.large_image_width.to_f / image_width.to_f
      if has_large? && ratio < 1
        (image_height * ratio).to_i
      else
        image_height
      end
    end

    def image_width_for(user)
      if user.default_image_size == "large"
        large_image_width
      else
        image_width
      end
    end

    def image_height_for(user)
      if user.default_image_size == "large"
        large_image_height
      else
        image_height
      end
    end

    def resize_percentage
      return 100 if image_width.to_i == 0
      100 * large_image_width.to_f / image_width.to_f
    end

    # XXX
    def current_image_size
      (has_large? && CurrentUser.default_image_size == "large") ? "large" : "original"
    end
  end

  concerning :ApprovalMethods do
    def in_modqueue?
      is_pending? || is_flagged? || is_appealed?
    end

    def is_active?
      !is_deleted? && !in_modqueue?
    end

    def is_appealed?
      is_deleted? && appeals.any?(&:pending?)
    end

    def is_appealable?
      is_deleted? && !is_appealed?
    end

    def is_approvable?(user = CurrentUser.user)
      !is_active? && (uploader != user || Pundit.policy!(user, PostApproval).can_approve_own_uploads?)
    end

    def autoban
      if has_tag?("paid_reward") || tags.any? { |tag| tag.artist? && tag.artist&.is_banned? }
        self.is_banned = true
      end
    end
  end

  concerning :PresenterMethods do
    def presenter
      @presenter ||= PostPresenter.new(self)
    end

    def status_flags
      flags = []
      flags << "pending" if is_pending?
      flags << "flagged" if is_flagged?
      flags << "deleted" if is_deleted?
      flags << "banned" if is_banned?
      flags.join(" ")
    end

    # g => 0, s => 1, q => 2, e => 3
    def rating_id
      RATINGS.keys.index(rating)
    end

    def pretty_rating
      RATINGS.fetch(rating)
    end

    def is_nsfw?
      rating.in?(%w[q e])
    end

    def parsed_source
      Source::URL.parse(source) if web_source?
    end

    def normalized_source
      parsed_source&.page_url || source
    end

    def source_domain
      parsed_source&.domain.to_s
    end
  end

  concerning :TagMethods do
    def tag_array
      tag_string.split
    end

    def tag_array_was
      tag_string_was.split
    end

    def tags
      Tag.where(name: tag_array)
    end

    def tags_was
      Tag.where(name: tag_array_was)
    end

    def added_tags
      tags - tags_was
    end

    def removed_tags
      tags_was - tags
    end

    def update_tag_post_counts
      decrement_tags = tag_array_was - tag_array

      increment_tags = tag_array - tag_array_was
      if increment_tags.any?
        Tag.increment_post_counts(increment_tags)
      end
      if decrement_tags.any?
        Tag.decrement_post_counts(decrement_tags)
      end
    end

    # Update tag_count_general, tag_count_copyright, etc.
    def update_tag_category_counts
      TagCategory.categories.each do |category_name|
        tag_count = tags.select { |t| t.category_name.downcase == category_name }.size
        send("tag_count_#{category_name}=", tag_count)
      end

      self.tag_count = tag_array.size
    end

    def merge_old_changes
      if old_parent_id == ""
        old_parent_id = nil
      else
        old_parent_id = old_parent_id.to_i
      end
      if old_parent_id == parent_id
        self.parent_id = parent_id_before_last_save || parent_id_was
      end

      if old_source == source.to_s
        self.source = source_before_last_save || source_was
      end

      if old_rating == rating
        self.rating = rating_before_last_save || rating_was
      end

      @post_edit = PostEdit.new(self, tag_string_was, old_tag_string || tag_string_was, tag_string)
    end

    # XXX should be a `validate` hook instead of `before_validation` hook
    def validate_new_tags
      return if CurrentUser.user.nil? || CurrentUser.user.is_builder?

      new_tags = post_edit.effective_added_tag_names.reject { |name| Tag.exists?(name: name) }

      if RateLimiter.limited?(action: "post:validate_new_tags", user: CurrentUser.user, cost: new_tags.size, rate: MAX_NEW_TAGS.to_f / MAX_NEW_TAGS_INTERVAL, burst: MAX_NEW_TAGS, minimum_points: -0.1)
        errors.add(:base, "You can't create more than #{MAX_NEW_TAGS.to_i} new tags per #{MAX_NEW_TAGS_INTERVAL.inspect}. Wait a while and try again")
        throw :abort # XXX This causes a transaction rollback which means the rate limit doesn't get properly updated.
      end
    end

    def normalize_tags
      self.tag_string = Tag.create_for_list(post_edit.tag_names).uniq.sort.join(" ")
    end

    def add_automatic_tags(tags)
      tags -= AUTOMATIC_TAGS

      if tags.size >= 30
        tags -= ["tagme"]
      elsif tags.empty?
        tags << "tagme"
      end

      if image_width >= 10_000 || image_height >= 10_000
        tags << "incredibly_absurdres"
      end
      if image_width >= 3200 || image_height >= 2400
        tags << "absurdres"
      end
      if image_width >= 1600 || image_height >= 1200
        tags << "highres"
      end
      if image_width <= 500 && image_height <= 500
        tags << "lowres"
      end

      if image_width >= 1024 && image_width.to_f / image_height >= 4
        tags << "wide_image"
      elsif image_height >= 1024 && image_height.to_f / image_width >= 4
        tags << "tall_image"
      end

      if is_flash?
        tags << "flash"
      end

      if is_video?
        tags << "video"
      end

      if is_ugoira?
        tags << "ugoira"
      end

      if source.present? && !web_source?
        tags << "non-web_source"
      end

      # A bad_link is an image URL from a recognized site that can't be converted to a page URL.
      case parsed_source&.bad_link?
      when true
        tags << "bad_link"
      when false
        tags -= ["bad_link"]
      when nil
        # it's unknown whether it's a bad link or not; don't add or remove the tag
      end

      # A bad_source is a source from a recognized site that isn't an image url or a page url.
      case parsed_source&.bad_source?
      when true
        tags << "bad_source"
      when false
        tags -= ["bad_source"]
      when nil
        # it's unknown whether it's a bad source or not; don't add or remove the tag
      end

      # Allow only Flash files to be manually tagged as `animated`; GIFs, PNGs, videos, and ugoiras are automatically tagged.
      tags -= ["animated"] unless is_flash?
      tags << "animated" if media_asset.is_animated?
      tags << "animated_gif" if media_asset.is_animated_gif?
      tags << "animated_png" if media_asset.is_animated_png?

      tags << "greyscale" if media_asset.is_greyscale?
      tags << "exif_rotation" if media_asset.is_rotated?
      tags << "non-repeating_animation" if media_asset.is_non_repeating_animation?
      tags << "ai-generated" if media_asset.is_ai_generated?

      # Allow Flash files to be manually tagged as `sound`; other files are automatically tagged.
      tags -= ["sound"] unless is_flash?
      tags << "sound" if media_asset.has_sound?

      tags
    end

    def apply_post_metatags
      post_edit.post_metatag_terms.each do |metatag|
        case [metatag.name, metatag.value]
        in "-pool", /^\d+$/ => pool_id
          pool = Pool.find_by_id(pool_id)
          remove_from_pool_or_warn(pool, pool_id)

        in "-pool", name
          pool = Pool.find_by_name(name)
          remove_from_pool_or_warn(pool, name)

        in "pool", /^\d+$/ => pool_id
          pool = Pool.find_by_id(pool_id)
          add_to_pool_or_warn(pool, pool_id)

        in "pool", "none"
          remove_from_all_pools

        in "pool", name
          pool = Pool.find_by_name(name)
          add_to_pool_or_warn(pool, name)

        in "newpool", name
          pool = Pool.find_by_name(name)

          # XXX race condition
          if pool.nil?
            # Said, not swallowed by the rescue below (boo.122 D5): a pool
            # that will not take this post, or a name it refuses.
            pool = Pool.new(name: name, description: "This pool was automatically generated", post_ids: [id])
            warnings.add(:base, "Couldn't create pool #{name}: #{pool.errors.full_messages.join("; ")}") unless pool.save
          else
            add_to_pool_or_warn(pool, name)
          end

        in "newfavgroup", name
          favgroup = FavoriteGroup.find_by_name_or_id(name, CurrentUser.user)

          # XXX race condition
          if favgroup.nil?
            FavoriteGroup.create!(name: name, creator: CurrentUser.user, post_ids: [id])
          else
            raise User::PrivilegeError unless Pundit.policy!(CurrentUser.user, favgroup).update?
            favgroup.add(self)
          end

        in "fav", name
          raise User::PrivilegeError unless Pundit.policy!(CurrentUser.user, Favorite).create?
          Favorite.create(post: self, user: CurrentUser.user)

        in "-fav", name
          raise User::PrivilegeError unless Pundit.policy!(CurrentUser.user, Favorite).create?
          Favorite.destroy_by(post: self, user: CurrentUser.user)

        in "upvote", name
          vote!(1, CurrentUser.user)

        in "downvote", name
          vote!(-1, CurrentUser.user)

        in "status", "active"
          raise User::PrivilegeError unless CurrentUser.is_approver?
          approvals.create!(user: CurrentUser.user)

        in "status", "banned"
          raise User::PrivilegeError unless CurrentUser.is_approver?
          ban!(CurrentUser.user)

        in "-status", "banned"
          raise User::PrivilegeError unless CurrentUser.is_approver?
          unban!(CurrentUser.user)

        in "disapproved", reason
          raise User::PrivilegeError unless CurrentUser.is_approver?
          disapprovals.create!(user: CurrentUser.user, reason: reason.downcase)

        # Fork: these write onto OTHER posts, so only onto the ones the
        # editor may write to (#writable_by?); any other is left alone, as a
        # missing id is (second review, 2026-10-08: child:<id of a post its
        # creator hid> made it this post's child).
        in "child", "none"
          children.select { |post| post.writable_by?(CurrentUser.user) }.each do |post|
            post.update!(parent_id: nil)
          end

        in "-child", ids
          next if ids.blank?

          children.where_numeric_matches(:id, ids).select { |post| post.writable_by?(CurrentUser.user) }.each do |post|
            post.update!(parent_id: nil)
          end

        in "child", ids
          next if ids.blank?

          Post.where_numeric_matches(:id, ids).where.not(id: id).limit(10).select { |post| post.writable_by?(CurrentUser.user) }.each do |post|
            post.update!(parent_id: id)
          end

        in "-favgroup", name
          favgroup = FavoriteGroup.find_by_name_or_id!(name, CurrentUser.user)
          raise User::PrivilegeError unless Pundit.policy!(CurrentUser.user, favgroup).update?
          favgroup&.remove(self)

        in "favgroup", name
          favgroup = FavoriteGroup.find_by_name_or_id!(name, CurrentUser.user)
          raise User::PrivilegeError unless Pundit.policy!(CurrentUser.user, favgroup).update?
          favgroup&.add(self)

        end
      end
    rescue StandardError
      # XXX Silently ignore errors so that the edit doesn't fail. We can't let
      # the edit fail because then it will create a new post version even if
      # the edit didn't go through.
      nil
    end

    # Fork (boo.122 D5): a pool:N or newpool: the pool refuses is said, not
    # dropped -- a full pool, or one that will not take this post
    # (Pool#added_posts_exist_for_writer). A missing pool stays silent, as
    # upstream left it.
    # A pool that is missing or deleted refuses too, and says so: Pool#add!
    # answers nil for a deleted pool and a nil pool was skipped, so a
    # "pool:typo" edit, or a convert into a pool deleted since, took the tag
    # off and seated the post nowhere without a word (boo.122).
    # -pool's half of the above: a missing pool, or a save the pool refused
    # (a deleted pool, for an editor its policy does not let update one),
    # said nothing, so a "-pool:typo" edit took the post out of nothing
    # without a word (boo.122). A post not in the pool has nothing to take out.
    def remove_from_pool_or_warn(pool, name)
      return warnings.add(:base, "Couldn't remove from pool #{name}: no pool has that name or id; check it") if pool.nil?
      return if pool.remove!(self) != false

      warnings.add(:base, "Couldn't remove from pool ##{pool.id}: #{pool.errors.full_messages.join("; ")}")
    end

    def add_to_pool_or_warn(pool, name)
      return warnings.add(:base, "Couldn't add to pool #{name}: no pool has that name or id; check it, or use newpool:#{name} to create one") if pool.nil?
      return if pool.contains?(id)
      return warnings.add(:base, "Couldn't add to pool ##{pool.id}: the pool is deleted; undelete it first") if pool.is_deleted?
      return if pool.add!(self) != false

      warnings.add(:base, "Couldn't add to pool ##{pool.id}: #{pool.errors.full_messages.join("; ")}")
    end

    def apply_pre_metatags
      post_edit.pre_metatag_terms.each do |metatag|
        case [metatag.name, metatag.value]
        in "parent", ("none" | "0")
          self.parent_id = nil

        in "-parent", /^\d+$/ => new_parent_id
          if parent_id == new_parent_id.to_i
            self.parent_id = nil
          end

        in "parent", new_parent_id
          self.parent_id = new_parent_id

        in "rating", /\A([#{RATINGS.keys.join}])/i
          self.rating = $1.downcase

        in "source", "none"
          self.source = ""

        in "source", value
          self.source = value

        in "status", "pending"
          self.is_pending = true if new_record?

        in category, name if category.in?(PostEdit::CATEGORIZATION_METATAGS)
          Tag.find_or_create_by_name(name, category: category, current_user: CurrentUser.user)

        else
          nil

        end
      end
    end

    def web_source?
      source.match?(%r{\Ahttps?://}i)
    end

    def file_source?
      source.starts_with?("file://")
    end

    def text_source?
      source.present? && !web_source? && !file_source?
    end

    def has_tag?(tag)
      tag_array.include?(tag)
    end

    def add_tag(*tags)
      self.tag_string = [tag_string, *tags].join(" ").strip
    end

    def remove_tag(*tags)
      self.tag_string = (tag_array - tags).join(" ")
    end

    def tag_categories
      @tag_categories ||= Tag.categories_for(tag_array)
    end

    def typed_tags(name)
      @typed_tags ||= {}
      @typed_tags[name] ||= tag_array.select do |tag|
        tag_categories[tag] == TagCategory.mapping[name]
      end
    end

    TagCategory.categories.each do |category|
      define_method("tag_string_#{category}") do
        typed_tags(category).join(" ")
      end
    end
  end

  concerning :FavoriteMethods do
    def favorited_by?(user)
      return false if user.is_anonymous?
      Favorite.exists?(post: self, user: user)
    end

    def favorite_groups
      FavoriteGroup.for_post(id)
    end

    def remove_from_fav_groups
      FavoriteGroup.for_post(id).find_each do |favgroup|
        favgroup.remove(self)
      end
    end
  end

  concerning :PoolMethods do
    def pools
      Pool.where_array_includes_all(:post_ids, [id])
    end

    def has_active_pools?
      pools.undeleted.present?
    end

    def remove_from_all_pools
      pools.find_each do |pool|
        pool.remove!(self)
      end
    end
  end

  concerning :VoteMethods do
    def vote!(score, voter)
      # Ignore vote if user doesn't have permission to vote.
      return unless Pundit.policy!(voter, PostVote).create?

      with_lock do
        votes.create!(user: voter, score: score) unless votes.active.exists?(user: voter, score: score)
        reload # PostVote.create modifies our score. Reload to get the new score.
      end
    end
  end

  concerning :ParentMethods do
    def parent=(new_parent)
      self.parent_id = new_parent&.id
    end

    def parent_id=(new_parent_id)
      super

      # Allow reversing a parent-child relationship by making the child into the parent without creating a loop.
      if parent != self && parent&.parent == self
        parent.parent_id = nil
      end
    end

    # @return [Array<Post>] The list of this post's ancestors (its parent, grandparent, great-grandparent, etc).
    def ancestors
      ancestors = []
      parent = self.parent

      while parent.present? && !in?(ancestors)
        ancestors << parent
        parent = parent.parent
      end

      ancestors
    end

    # @return [Integer] The total number of levels in the entire parent-child tree. A post with no parent or
    # children has depth 1; a post with a parent but no children has depth 2; a post with a parent and one level of
    # children has depth 3; etc.
    def parent_hierarchy_depth
      ancestors.size + child_height + 1
    end

    # #parent_hierarchy_depth over the relatives `viewer` may be told of: a
    # hidden parent is no parent (#parent_id_shown_to) and a hidden child no
    # child (#children_shown_to). Every post, with no viewer.
    def parent_hierarchy_depth_shown_to(viewer)
      return parent_hierarchy_depth if viewer.nil?

      ancestors_shown_to(viewer).size + child_height_shown_to(viewer) + 1
    end

    def ancestors_shown_to(viewer)
      ancestors.take_while { |ancestor| !ancestor.hidden_from?(viewer) }
    end

    def child_height_shown_to(viewer)
      shown = children.reject { |child| child.hidden_from?(viewer) }
      shown.empty? ? 0 : shown.map { |child| child.child_height_shown_to(viewer) }.max + 1
    end

    # @return [Integer] The number of levels of child posts this post has. A post with no children has height 0; a post
    # with children but no grandchildren has height 1; a post with grandchildren but no great-grandchildren has height 2; etc.
    def child_height
      if children.present?
        children.map(&:child_height).max + 1
      else
        0
      end
    end

    def update_has_children_flag
      update(has_children: children.exists?, has_active_children: children.undeleted.exists?)
    end

    def update_parent_on_destroy
      parent&.update_has_children_flag
    end

    def update_children_on_destroy
      children.update(parent: nil)
    end

    def update_parent_on_save
      return unless saved_change_to_parent_id? || saved_change_to_is_deleted?

      parent.presence&.update_has_children_flag
      Post.find(parent_id_before_last_save).update_has_children_flag if parent_id_before_last_save.present?
    rescue StandardError
      # XXX Silently ignore errors so that the edit doesn't fail. We can't let
      # the edit fail because then it will create a new post version even if
      # the edit didn't go through.
      nil
    end

    # Fork: only onto a parent the mover may write to (#writable_by?) -- a
    # moderator moving a deleted child's favorites wrote them onto a post its
    # creator hid from them (second review, 2026-10-08). With no parent, or
    # one hidden from the mover, the move is REFUSED with
    # NO_PARENT_FOR_FAVORITES, in the same words for both so the refusal
    # cannot tell a hidden parent from none. Raised inside #delete!'s lock, it
    # undoes the delete it was asked to come with: until 2026-11-20 it
    # returned quietly and a "delete and move favorites" reported success
    # having moved nothing.
    def give_favorites_to_parent(current_user = CurrentUser.user)
      raise User::PrivilegeError, NO_PARENT_FOR_FAVORITES if parent.nil? || !parent.writable_by?(current_user)

      transaction do
        favorites.each do |fav|
          fav.destroy!
          Favorite.create(post: parent, user: fav.user)
        end
      end

      ModAction.log("moved favorites from post ##{id} to post ##{parent.id}", :post_move_favorites, subject: self, user: current_user)
    end

    # Fork: of the children that exist for `viewer` (#children_shown_to)
    # rather than the stored flags, which count every child: a visible
    # parent whose only live child its creator hid said it had children in
    # its JSON, its thumbnail border and its page (second review, 2026-10-08).
    def has_visible_children?(viewer = CurrentUser.user)
      shown = children_shown_to(viewer)
      return true if shown.any? { |child| !child.is_deleted? }
      return true if shown.any? && viewer.show_deleted_children?
      return true if shown.any? && is_deleted?
      false
    end

    def has_visible_children
      has_visible_children?
    end

    # The children that exist for `viewer`: every child but those hidden
    # from them (#hidden_from? -- deleted past what they may see, a
    # creator's narrowing, a hidden creator prefix, gated below Gold). Read
    # fresh, not
    # through the children association, which a save's own validations load
    # before child: metatags change it; and only for a post whose flag says
    # it has children, so a gallery pays one query per parent, not per post.
    def children_shown_to(viewer)
      return [] unless has_children?

      (@children_shown_to ||= {})[viewer&.id] ||= Post.unscoped.where(parent_id: id).reject { |child| child.hidden_from?(viewer) }
    end

    # parent_id, unless the parent does not exist for `viewer` (as above).
    def parent_id_shown_to(viewer)
      parent_id unless parent_id.present? && parent&.hidden_from?(viewer)
    end

    # The stored relationship columns as `viewer` may be told them -- what a
    # post's JSON and its page's data attributes carry. A deleted relative is
    # named only to a viewer who may see it: a visible child's JSON and page
    # named its deleted parent's id to anyone (2026-11-19; jailed means
    # deleted, operator 2026-10-10).
    def relationship_attributes_shown_to(viewer)
      shown = children_shown_to(viewer)
      {
        parent_id: parent_id_shown_to(viewer),
        has_children: shown.any?,
        has_active_children: shown.any? { |child| !child.is_deleted? },
        has_visible_children: has_visible_children?(viewer),
      }
    end
  end

  concerning :DeletionMethods do
    def expunge!(current_user = CurrentUser.user)
      transaction do
        Post.without_timeout do
          ModAction.log("permanently deleted post ##{id} (md5=#{md5})", :post_permanent_delete, subject: nil, user: current_user)

          update_children_on_destroy
          Tag.decrement_post_counts(tag_array)
          remove_from_all_pools
          remove_from_fav_groups
          media_asset.trash!(current_user, log: false)
          destroy
          update_parent_on_destroy
        end
      end

      remove_iqdb # this is non-transactional
    end

    def ban!(current_user)
      return if is_banned?
      update_column(:is_banned, true)
      ModAction.log("banned post ##{id}", :post_ban, subject: self, user: current_user)
    end

    def unban!(current_user)
      return unless is_banned?
      update_column(:is_banned, false)
      ModAction.log("unbanned post ##{id}", :post_unban, subject: self, user: current_user)
    end

    def delete!(reason, move_favorites: false, user: CurrentUser.user)
      with_lock do
        automated = (user == User.system)

        flags.pending.update!(status: :succeeded)
        appeals.pending.update!(status: :rejected)

        flags.create!(reason: reason, is_deletion: true, creator: user, status: :succeeded)
        update!(is_deleted: true, is_pending: false, is_flagged: false)

        # XXX This must happen *after* the `is_deleted` flag is set to true (issue #3419).
        give_favorites_to_parent(user) if move_favorites

        uploader.upload_limit.update_limit!(is_pending?, false)

        unless automated
          ModAction.log("deleted post ##{id}, reason: #{reason}", :post_delete, subject: self, user: user)
        end
      end
    end
  end

  concerning :VersionMethods do
    # XXX `create_version` must be called before `apply_post_metatags` because
    # `apply_post_metatags` may update the post itself, which will clear all
    # changes to the post and make saved_change_to_*? return false.
    def create_version(force = false)
      if new_record? || saved_change_to_watched_attributes? || force
        create_new_version
      end
    end

    def saved_change_to_watched_attributes?
      saved_change_to_rating? || saved_change_to_source? || saved_change_to_parent_id? || saved_change_to_tag_string?
    end

    def merge_version?
      prev = versions.last
      prev && prev.updater_id == CurrentUser.user.id && prev.updated_at > 1.hour.ago
    end

    def create_new_version
      User.where(id: CurrentUser.id).update_all("post_update_count = post_update_count + 1")
      PostVersion.queue(self) if PostVersion.enabled?
    end

    def revert_to(target)
      if id != target.post_id
        raise RevertError, "You cannot revert to a previous version of another post."
      end

      # Fork: never publishes a creator's private tag again (BUR review
      # 2026-10-19, M2): a version from before FourierPrivateTagCleanup holds
      # what the posting bot leaked, and history withholds it from the very
      # person reverting. Refused unless they are the post's creator.
      FourierPrivateTagLineage.refuse_restore!(self, target.tag_array, source: target)

      self.tag_string = target.tags
      self.rating = target.rating
      self.source = target.source
      self.parent_id = target.parent_id
    end

    def revert_to!(target)
      revert_to(target)
      save!
    end
  end

  concerning :NoteMethods do
    def can_have_notes?
      is_image?
    end

    def has_notes?
      last_noted_at.present?
    end

    def copy_notes_to(other_post, copy_tags: NOTE_COPY_TAGS)
      transaction do
        if id == other_post.id
          errors.add(:base, "Source and destination posts are the same")
          return false
        end
        unless has_notes?
          errors.add(:post, "has no notes")
          return false
        end

        notes.active.each do |note|
          note.copy_to(other_post)
        end

        dummy = Note.new
        if notes.active.length == 1
          dummy.body = "Copied 1 note from post ##{id}."
        else
          dummy.body = "Copied #{notes.active.length} notes from post ##{id}."
        end
        dummy.is_active = false
        dummy.post_id = other_post.id
        dummy.x = dummy.y = dummy.width = dummy.height = 0
        dummy.save

        copy_tags.each do |tag|
          other_post.remove_tag(tag)
          other_post.add_tag(tag) if has_tag?(tag)
        end

        other_post.has_embedded_notes = has_embedded_notes
        other_post.save
      end
    end
  end

  concerning :ApiMethods do
    # Fork: the relationship columns as the viewer may be told them
    # (#relationship_attributes_shown_to): a visible child's JSON named its
    # hidden parent's id, and a visible parent's said it had children when
    # its only one was hidden (second review, 2026-10-08). Only the keys
    # the answer carries, so a post with no relatives queries nothing.
    def serializable_hash(...)
      hash = super
      keys = %w[parent_id has_children has_active_children has_visible_children] & hash.keys
      return hash if keys.empty?

      hash.merge(relationship_attributes_shown_to(CurrentUser.user).stringify_keys.slice(*keys))
    end

    def legacy_attributes
      shown = relationship_attributes_shown_to(CurrentUser.user)
      hash = {
        "has_comments" => last_commented_at.present?,
        "parent_id" => shown[:parent_id],
        "status" => status,
        "has_children" => shown[:has_children],
        "created_at" => created_at.to_fs(:db),
        "has_notes" => has_notes?,
        "rating" => rating,
        "author" => uploader.name,
        "creator_id" => uploader_id,
        "width" => image_width,
        "source" => source,
        "score" => score,
        "tags" => tag_string,
        "height" => image_height,
        "file_size" => file_size,
        "id" => id,
      }

      if visible?
        hash["file_url"] = file_url
        hash["preview_url"] = preview_file_url
        hash["md5"] = md5
      end

      hash
    end

    def status
      if is_pending?
        "pending"
      elsif is_deleted?
        "deleted"
      elsif is_flagged?
        "flagged"
      else
        "active"
      end
    end
  end

  concerning :SearchMethods do
    class_methods do
      # Return a set of up to N random posts. May return less if it can't find enough posts.
      #
      # Works by generating N random MD5s and picking the closest post below each MD5 (or above it if there aren't any
      # posts below it). For small searches, this procedure is noticeably biased. It may return less than N posts and
      # some posts may be more likely to be returned than others. This is because MD5s aren't evenly distributed for
      # small searches.
      #
      # @param limit [Integer] The maximum number of posts to return.
      # @return [ActiveRecord::Relation<Post>] The set of random posts.
      def random(limit = 1)
        random_md5s = <<~SQL
          WITH RECURSIVE random_md5s (n, r, md5) AS (
              SELECT 0, random(), NULL::text
            UNION ALL
              SELECT
                n+1,
                r+1,
                (((#{reselect(:md5).where("posts.md5 < md5((n + r)::text)").reorder(md5: :desc).limit(1).to_sql}) UNION ALL
                  (#{reselect(:md5).where("posts.md5 >= md5((n + r)::text)").reorder(md5: :asc).limit(1).to_sql})) LIMIT 1)
              FROM random_md5s
              WHERE n+1 < #{limit + 1}
          )
          SELECT DISTINCT md5 FROM random_md5s
        SQL

        where("posts.md5 IN (#{random_md5s})").reorder("random()")
      end

      def sample(query, sample_size)
        user_tag_match(query, safe_mode: false).reorder(:md5).limit(sample_size)
      end

      # unflattens the tag_string into one tag per row.
      def with_unflattened_tags
        joins("CROSS JOIN unnest(string_to_array(tag_string, ' ')) AS tag")
      end

      def with_comment_stats
        relation = left_outer_joins(:comments).group(:id).select("posts.*")
        relation = relation.select("COUNT(comments.id) AS comment_count")
        relation = relation.select("COUNT(comments.id) FILTER (WHERE comments.is_deleted = TRUE)  AS deleted_comment_count")
        relation = relation.select("COUNT(comments.id) FILTER (WHERE comments.is_deleted = FALSE) AS active_comment_count")
        relation
      end

      def with_note_stats
        relation = left_outer_joins(:notes).group(:id).select("posts.*")
        relation = relation.select("COUNT(notes.id) AS note_count")
        relation = relation.select("COUNT(notes.id) FILTER (WHERE notes.is_active = TRUE)  AS active_note_count")
        relation = relation.select("COUNT(notes.id) FILTER (WHERE notes.is_active = FALSE) AS deleted_note_count")
        relation
      end

      def with_flag_stats
        relation = left_outer_joins(:flags).group(:id).select("posts.*")
        relation.select("COUNT(post_flags.id) AS flag_count")
      end

      def with_appeal_stats
        relation = left_outer_joins(:appeals).group(:id).select("posts.*")
        relation = relation.select("COUNT(post_appeals.id) AS appeal_count")
        relation
      end

      def with_approval_stats
        relation = left_outer_joins(:approvals).group(:id).select("posts.*")
        relation = relation.select("COUNT(post_approvals.id) AS approval_count")
        relation
      end

      def with_disapproval_stats
        relation = left_outer_joins(:disapprovals).group(:id).select("posts.*")
        relation = relation.select("COUNT(post_disapprovals.id) AS disapproval_count")
        relation
      end

      def with_replacement_stats
        relation = left_outer_joins(:replacements).group(:id).select("posts.*")
        relation = relation.select("COUNT(post_replacements.id) AS replacement_count")
        relation
      end

      def with_child_stats
        relation = left_outer_joins(:children).group(:id).select("posts.*")
        relation = relation.select("COUNT(children_posts.id) AS child_count")
        relation = relation.select("COUNT(children_posts.id) FILTER (WHERE children_posts.is_deleted = TRUE)  AS deleted_child_count")
        relation = relation.select("COUNT(children_posts.id) FILTER (WHERE children_posts.is_deleted = FALSE) AS active_child_count")
        relation
      end

      def with_pool_stats
        pool_posts = Pool.joins("CROSS JOIN unnest(post_ids) AS post_id").select(:id, :is_deleted, :category, "post_id")
        relation = joins("LEFT OUTER JOIN (#{pool_posts.to_sql}) pools ON pools.post_id = posts.id").group(:id).select("posts.*")

        relation = relation.select("COUNT(pools.id) AS pool_count")
        relation = relation.select("COUNT(pools.id) FILTER (WHERE pools.is_deleted = TRUE) AS deleted_pool_count")
        relation = relation.select("COUNT(pools.id) FILTER (WHERE pools.is_deleted = FALSE) AS active_pool_count")
        relation = relation.select("COUNT(pools.id) FILTER (WHERE pools.category = 'series') AS series_pool_count")
        relation = relation.select("COUNT(pools.id) FILTER (WHERE pools.category = 'collection') AS collection_pool_count")
        relation
      end

      def with_queued_at
        relation = group(:id)
        relation = relation.left_outer_joins(:flags, :appeals)
        relation = relation.select("posts.*")
        relation = relation.select(Arel.sql("MAX(GREATEST(posts.created_at, post_flags.created_at, post_appeals.created_at)) AS queued_at"))
        relation
      end

      def with_stats(tables)
        return all if tables.empty?

        relation = all
        tables.each do |table|
          relation = relation.send("with_#{table}_stats")
        end

        from(relation.arel.as("posts"))
      end

      def available_for_moderation(user, type)
        disapproved_posts = user.post_disapprovals.select(:post_id)

        case type.to_s
        when "seen"
          in_modqueue.where(id: disapproved_posts)
        when "unseen"
          in_modqueue.where.not(id: disapproved_posts)
        else
          in_modqueue
        end
      end

      def metatag_matches(name, value, current_user = User.anonymous, quoted: false)
        # Only allow exact hash matches for non-moderators, so range searches can't be used to find the md5s of hidden posts.
        if name.in?(%w[md5 pixelhash]) && !current_user.is_moderator?
          exact = begin
            RangeParser.parse(value, :md5) in [:eq | :in, _]
          rescue RangeParser::ParseError
            false
          end
          return none unless exact
        end

        case name
        when "id"
          attribute_matches(value, :id)
        when "md5"
          attribute_matches(value, :md5, :md5)
        when "pixelhash"
          attribute_matches(value, "media_assets.pixel_hash", :md5).joins(:media_asset)
        when "width"
          attribute_matches(value, "media_assets.image_width").joins(:media_asset)
        when "height"
          attribute_matches(value, "media_assets.image_height").joins(:media_asset)
        when "mpixels"
          attribute_matches(value, "(media_assets.image_width * media_assets.image_height) / 1000000.0", :float).joins(:media_asset)
        when "ratio"
          attribute_matches(value, "ROUND(media_assets.image_width::numeric / media_assets.image_height::numeric, 2)", :ratio).joins(:media_asset)
        when "score"
          attribute_matches(value, :score)
        when "upvotes"
          attribute_matches(value, :up_score)
        when "downvotes"
          attribute_matches(value, "ABS(posts.down_score)")
        when "favcount"
          attribute_matches(value, :fav_count)
        when "filesize"
          attribute_matches(value, "media_assets.file_size", :filesize).joins(:media_asset)
        when "filetype"
          attribute_matches(value, "media_assets.file_ext", :enum).joins(:media_asset)
        when "date"
          attribute_matches(value, :created_at, :date)
        when "age"
          attribute_matches(value, :created_at, :age)
        when "pixiv", "pixiv_id"
          attribute_matches(value, :pixiv_id)
        when "tagcount"
          attribute_matches(value, :tag_count)
        when "duration"
          attribute_matches(value, "media_assets.duration", :duration).joins(:media_asset)
        when "is"
          is_matches(value, current_user)
        when "has"
          has_matches(value, current_user)
        when "status"
          status_matches(value, current_user)
        when "parent"
          parent_matches(value, current_user)
        when "child"
          child_matches(value, current_user)
        when "rating"
          rating_matches(value)
        when "embedded"
          embedded_matches(value)
        when "source"
          source_matches(value, quoted)
        when "holds"
          holds_matches(value)
        when "disapproved"
          disapproved_matches(value, current_user)
        when "commentary"
          commentary_matches(value, quoted)
        when "note"
          note_matches(value)
        when "comment"
          comment_matches(value, current_user)
        when "search"
          saved_search_matches(value, current_user)
        when "pool"
          pool_matches(value)
        when "ordpool"
          ordpool_matches(value)
        when "favgroup"
          favgroup_matches(value, current_user)
        when "ordfavgroup"
          ordfavgroup_matches(value, current_user)
        when "fav"
          favorites_include(value, current_user)
        when "ordfav"
          ordfav_matches(value, current_user)
        when "ordvote"
          ordvote_matches(value, current_user)
        when "reacted"
          reacted_by(value)
        when "unaliased"
          tags_include(value)
        when "exif"
          exif_matches(value)
        when "ai"
          ai_tags_include(value, current_user: current_user)
        when "user"
          uploader_matches(value)
        when "approver"
          approver_matches(value)
        when "flagger"
          user_subquery_matches(PostFlag.unscoped.category_matches("normal"), value, current_user)
        when "appealer"
          user_subquery_matches(PostAppeal.unscoped, value, current_user)
        when "commenter", "comm"
          user_subquery_matches(Comment.unscoped, value, current_user)
        when "commentaryupdater", "artcomm"
          user_subquery_matches(ArtistCommentaryVersion.unscoped, value, current_user, field: :updater)
        when "noter"
          user_subquery_matches(NoteVersion.unscoped.where(version: 1), value, current_user, field: :updater)
        when "noteupdater"
          user_subquery_matches(NoteVersion.unscoped, value, current_user, field: :updater)
        when "upvoter", "upvote"
          user_subquery_matches(PostVote.active.positive.visible(current_user), value, current_user, field: :user)
        when "downvoter", "downvote"
          user_subquery_matches(PostVote.active.negative.visible(current_user), value, current_user, field: :user)
        when *PostQueryBuilder::CATEGORY_COUNT_METATAGS
          short_category = name.delete_suffix("tags")
          category = TagCategory.short_name_mapping[short_category]
          attribute_matches(value, :"tag_count_#{category}")
        when *PostQueryBuilder::COUNT_METATAGS
          attribute_matches(value, name.to_sym)
        when "random"
          all # handled elsewhere
        when "limit"
          all
        when "order"
          all
        else
          raise NotImplementedError, "metatag not implemented"
        end
      end

      def is_matches(value, current_user = User.anonymous)
        case value.downcase
        when "parent"
          child_matches("any", current_user)
        when "child"
          parent_matches("any", current_user)
        when "wiki_image"
          where(id: DtextLink.wiki_page.embedded_post.select("link_target::integer"))
        when *AutocompleteService::POST_STATUSES
          status_matches(value, current_user)
        when *MediaAsset::FILE_TYPES
          attribute_matches(value, "media_assets.file_ext", :enum).joins(:media_asset)
        when *Post::RATINGS.values.map(&:downcase)
          rating_matches(value)
        when *Post::RATING_ALIASES.keys
          where(rating: Post::RATING_ALIASES.fetch(value.downcase))
        else
          none
        end
      end

      def has_matches(value, current_user = User.anonymous)
        case value.downcase
        when "parent"
          parent_matches("any", current_user)
        when "child", "children"
          child_matches("any", current_user)
        when "source"
          where.not(source: "")
        when "appeals"
          where(PostAppeal.where("post_appeals.post_id = posts.id").arel.exists)
        when "flags"
          where(PostFlag.by_users.where("post_flags.post_id = posts.id").arel.exists)
        when "replacements"
          where(PostReplacement.where("post_replacements.post_id = posts.id").arel.exists)
        when "comments"
          where(Comment.undeleted.where("comments.post_id = posts.id").arel.exists)
        when "commentary"
          where(ArtistCommentary.undeleted.where("artist_commentaries.post_id = posts.id").arel.exists)
        when "notes"
          where(Note.active.where("notes.post_id = posts.id").arel.exists)
        when "pools"
          where(id: Pool.undeleted.select("unnest(post_ids)"))
        else
          none
        end
      end

      def status_matches(status, current_user = User.anonymous)
        case status.downcase
        when "pending"
          pending
        when "flagged"
          flagged
        when "appealed"
          appealed
        when "modqueue"
          in_modqueue
        when "deleted"
          deleted
        when "banned"
          banned
        when "active"
          active
        when "unmoderated"
          available_for_moderation(current_user, :unseen)
        when "all", "any"
          where("TRUE")
        else
          none
        end
      end

      # Fork: a parent hidden from the searcher is no parent
      # (#parent_id_shown_to). Its id matches what a missing id matches,
      # nothing -- parent:<id of a post its creator hid> listed its visible
      # children (second review, 2026-10-08), and so did parent:<id of a
      # deleted post> (2026-11-19) -- and its children are parent:none, not
      # parent:any (Post.unnamed_parent_sql).
      def parent_matches(parent, current_user = User.anonymous)
        unnamed = Post.unnamed_parent_sql(current_user)

        case parent.downcase
        when "none"
          unnamed ? where(parent: nil).or(where(unnamed)) : where(parent: nil)
        when "any"
          unnamed ? where.not(parent: nil).where.not(unnamed) : where.not(parent: nil)
        when "pending", "flagged", "appealed", "modqueue", "deleted", "banned", "active", "unmoderated"
          found = where.not(parent: nil).where(parent: status_matches(parent))
          unnamed ? found.where.not(unnamed) : found
        when /\A\d+\z/
          parent = "0" if Post.unscoped.find_by(id: parent)&.hidden_from?(current_user)
          # XXX must use `attribute_matches(parent, :parent_id)` instead of `where(parent_id: parent)` so that `-parent:1` works
          where(id: parent).or(attribute_matches(parent, :parent_id))
        else
          none
        end
      end

      # Fork: of the children the searcher may be told of
      # (Post.named_child_sql), not the stored flag, which counts a deleted
      # child too.
      def child_matches(child, current_user = User.anonymous)
        named = Post.named_child_sql(current_user)

        case child.downcase
        when "none"
          named ? where(has_children: false).or(where.not(named)) : where(has_children: false)
        when "any"
          named ? where(has_children: true).where(named) : where(has_children: true)
        when "pending", "flagged", "appealed", "modqueue", "deleted", "banned", "active", "unmoderated"
          among = status_matches(child)
          named = Post.named_child_sql(current_user, among)
          named ? where(has_children: true).where(named) : where(has_children: true).where(children: among)
        else
          none
        end
      end

      def rating_matches(rating)
        where(rating: rating.downcase.split(",").map(&:first))
      end

      def source_matches(source, quoted = false)
        if source.empty?
          where(source: "")
        elsif source.downcase == "none" && !quoted
          where(source: "")
        else
          where_ilike(:source, source + "*")
        end
      end

      # holds:<identity> -- the posts holding an image by ANY of its
      # identities (operator, 2026-10-16: "No copies of objects, is a
      # given"), so a caller holding one name of a picture finds its post:
      #
      #   mxc://...  post_mxcs.mxc -- the post's own Matrix source and every
      #              alias the tunnel's duplicate path mapped to it -- or
      #              posts.source;
      #   32 hex     posts.md5, or the other md5 of the same upload on its
      #              generation record (FourierGenerationMetadata: raw_md5,
      #              the bytes the tunnel was handed, and md5, the stripped
      #              bytes it posted), mapped to the post carrying it.
      #
      # Anything else matches nothing. Each lookup is a unique index (post_mxcs
      # mxc, fourier_generation_metadata md5 and raw_md5) feeding posts' own
      # (primary key, md5, and source's trigram index, which answers =), as
      # ARRAY(...) init plans: one query, and no NULL from an empty lookup, so
      # -holds: negates exactly. Visibility is the search's, as for any term.
      def holds_matches(value)
        if value.start_with?("mxc://")
          where("posts.id = ANY(ARRAY(SELECT post_mxcs.post_id FROM post_mxcs WHERE post_mxcs.mxc = :mxc)) OR posts.source = :mxc", mxc: value)
        elsif value.match?(/\A\h{32}\z/)
          where(<<~SQL.squish, md5: value.downcase)
            posts.md5 = ANY(ARRAY[:md5]::varchar[]
              || ARRAY(SELECT fgm.md5 FROM fourier_generation_metadata fgm WHERE fgm.raw_md5 = :md5)
              || ARRAY(SELECT fgm.raw_md5 FROM fourier_generation_metadata fgm WHERE fgm.md5 = :md5 AND fgm.raw_md5 IS NOT NULL))
          SQL
        else
          none
        end
      end

      def embedded_matches(embedded)
        if embedded.truthy?
          bit_flags_match(:has_embedded_notes, true)
        elsif embedded.falsy?
          bit_flags_match(:has_embedded_notes, false)
        else
          none
        end
      end

      def commentary_matches(query, quoted = false)
        case query.downcase
        in "none" | "false" unless quoted
          where.not(artist_commentary: ArtistCommentary.all).or(where(artist_commentary: ArtistCommentary.deleted))
        in "any" | "true" unless quoted
          where(artist_commentary: ArtistCommentary.undeleted)
        in "translated" unless quoted
          where(artist_commentary: ArtistCommentary.translated)
        in "untranslated" unless quoted
          where(artist_commentary: ArtistCommentary.untranslated)
        else
          where(artist_commentary: ArtistCommentary.text_matches(query))
        end
      end

      def disapproved_matches(query, current_user = User.anonymous)
        if query.downcase.in?(PostDisapproval::REASONS)
          where(disapprovals: PostDisapproval.where(reason: query.downcase))
        else
          user = User.find_by_name(query)
          where(disapprovals: PostDisapproval.visible_for_search(:user, current_user).where(user: user))
        end
      end

      def note_matches(query)
        where(notes: Note.where_text_matches(:body, query))
      end

      def comment_matches(query, current_user)
        where(comments: Comment.visible_for_search(:body, current_user).where_text_matches(:body, query))
      end

      def saved_search_matches(label, current_user = User.anonymous)
        case label.downcase
        when "all"
          where(id: SavedSearch.post_ids_for(current_user.id))
        else
          where(id: SavedSearch.post_ids_for(current_user.id, label: label))
        end
      end

      def pool_matches(pool_name)
        case pool_name.downcase
        when "none"
          where.not(id: Pool.select("unnest(post_ids)"))
        when "any"
          where(id: Pool.select("unnest(post_ids)"))
        when "series"
          where(id: Pool.series.select("unnest(post_ids)"))
        when "collection"
          where(id: Pool.collection.select("unnest(post_ids)"))
        when /\*/
          where(id: Pool.name_contains(pool_name).select("unnest(post_ids)"))
        else
          where(id: Pool.named(pool_name).select("unnest(post_ids)"))
        end
      end

      def ordpool_matches(pool_name)
        # XXX unify with Pool#posts
        pool_posts = Pool.named(pool_name).joins("CROSS JOIN unnest(pools.post_ids) WITH ORDINALITY AS row(post_id, pool_index)").select(:post_id, :pool_index)
        joins("JOIN (#{pool_posts.to_sql}) pool_posts ON pool_posts.post_id = posts.id").order("pool_posts.pool_index ASC")
      end

      def favgroup_matches(query, current_user)
        case query.downcase
        when "none"
          favgroups = FavoriteGroup.where(creator: current_user)
          where.not(id: favgroups.select("unnest(post_ids)"))
        when "any"
          favgroups = FavoriteGroup.where(creator: current_user)
          where(id: favgroups.select("unnest(post_ids)"))
        else
          favgroup = FavoriteGroup.visible(current_user).name_or_id_matches(query, current_user)
          where(id: favgroup.select("unnest(post_ids)"))
        end
      end

      def ordfavgroup_matches(query, current_user)
        # XXX unify with FavoriteGroup#posts
        favgroup = FavoriteGroup.visible(current_user).name_or_id_matches(query, current_user)
        favgroup_posts = favgroup.joins("CROSS JOIN unnest(favorite_groups.post_ids) WITH ORDINALITY AS row(post_id, favgroup_index)").select(:post_id, :favgroup_index)
        joins("JOIN (#{favgroup_posts.to_sql}) favgroup_posts ON favgroup_posts.post_id = posts.id").order("favgroup_posts.favgroup_index ASC")
      end

      def favorites_include(username, current_user = User.anonymous)
        favuser = User.find_by_name(username)

        if favuser.present? && Pundit.policy!(current_user, favuser).can_see_favorites?
          where(id: favuser.favorites.select(:post_id))
        else
          none
        end
      end

      def ordfav_matches(username, current_user = User.anonymous)
        user = User.find_by_name(username)

        if user.present? && Pundit.policy!(current_user, user).can_see_favorites?
          joins(:favorites).merge(Favorite.where(user: user)).order("favorites.id DESC")
        else
          none
        end
      end

      def ordvote_matches(username, current_user = User.anonymous)
        user = User.find_by_name(username)

        if user.present?
          joins(:votes).merge(PostVote.active.visible(current_user).where(user: user)).order("post_votes.id DESC")
        else
          none
        end
      end

      def reacted_by(username)
        reactor = User.find_by_name(username)

        if reactor.present?
          where(id: reactor.post_reactions.select(:model_id))
        else
          none
        end
      end

      def exif_matches(string)
        joins(:media_asset).merge(MediaAsset.exif_matches(string))
      end

      # Fork: a tag whose name is hidden from the searcher (a quarantined
      # name, TagQuarantine) matches nothing, as a name never used does --
      # ai:<hidden name> would otherwise list the visible posts the
      # autotagger scored for it.
      def ai_tags_include(value, default_confidence: ">=50", current_user: CurrentUser.user)
        name, confidence = value.split(",")
        confidence = (confidence || default_confidence).to_s.delete("%")

        tag = Tag.find_by_name_or_alias(name)
        return none if tag.nil? || TagQuarantine.hidden_name?(tag.name, current_user)

        if confidence == "0"
          ai_tags = AITag.joins(:media_asset).where(tag: tag)
          where.not(ai_tags.where("media_assets.md5 = posts.md5").arel.exists)
        else
          ai_tags = AITag.joins(:media_asset).where(tag: tag).where_numeric_matches(:score, confidence)
          where(ai_tags.where("media_assets.md5 = posts.md5").arel.exists)
        end
      end

      def uploader_matches(username)
        case username.downcase
        when "any"
          where.not(uploader: nil)
        when "none"
          where(uploader: nil)
        else
          user = User.find_by_name(username)
          return none if user.nil?
          where(uploader: user)
        end
      end

      def approver_matches(username)
        case username.downcase
        when "any"
          where.not(approver: nil)
        when "none"
          where(approver: nil)
        else
          user = User.find_by_name(username)
          return none if user.nil?

          # XXX must use `attribute_matches(user.id, :approver_id)` instead of `where(approver: user)` so that `-approver:evazion` works
          attribute_matches(user.id, :approver_id)
        end
      end

      def user_subquery_matches(subquery, username, current_user, field: :creator)
        subquery = subquery.where("post_id = posts.id").select(1)

        if username.downcase == "any"
          where("EXISTS (#{subquery.to_sql})")
        elsif username.downcase == "none"
          where("NOT EXISTS (#{subquery.to_sql})")
        else
          user = User.find_by_name(username)
          return none if user.nil?
          subquery = subquery.visible_for_search(field, current_user).where(field => user)
          where("EXISTS (#{subquery.to_sql})")
        end
      end

      def order_matches(order)
        case order.to_s.downcase
        when "id", "id_asc"
          reorder("posts.id ASC")

        when "id_desc"
          reorder("posts.id DESC")

        when "md5", "md5_desc"
          reorder("posts.md5 DESC")

        when "md5_asc"
          reorder("posts.md5 ASC")

        when "score", "score_desc"
          reorder("posts.score DESC, posts.id DESC")

        when "score_asc"
          reorder("posts.score ASC, posts.id ASC")

        when "upvotes", "upvotes_desc"
          reorder("posts.up_score DESC, posts.id DESC")

        when "upvotes_asc"
          reorder("posts.up_score ASC, posts.id ASC")

        # XXX down_score is negative so order:downvotes sorts lowest-to-highest so that most downvoted is first.
        when "downvotes", "downvotes_desc"
          reorder("posts.down_score ASC, posts.id ASC")

        when "downvotes_asc"
          reorder("posts.down_score DESC, posts.id DESC")

        when "favcount"
          reorder("posts.fav_count DESC, posts.id DESC")

        when "favcount_asc"
          reorder("posts.fav_count ASC, posts.id ASC")

        when "created_at", "created_at_desc"
          reorder("posts.created_at DESC")

        when "created_at_asc"
          reorder("posts.created_at ASC")

        when "change", "change_desc"
          reorder("posts.updated_at DESC, posts.id DESC")

        when "change_asc"
          reorder("posts.updated_at ASC, posts.id ASC")

        when "comment", "comm"
          reorder("posts.last_commented_at DESC NULLS LAST, posts.id DESC")

        when "comment_asc", "comm_asc"
          reorder("posts.last_commented_at ASC NULLS LAST, posts.id ASC")

        when "comment_bumped"
          reorder("posts.last_comment_bumped_at DESC NULLS LAST")

        when "comment_bumped_asc"
          reorder("posts.last_comment_bumped_at ASC NULLS FIRST")

        when "note"
          reorder("posts.last_noted_at DESC NULLS LAST")

        when "note_asc"
          reorder("posts.last_noted_at ASC NULLS FIRST")

        when "artcomm"
          joins(:artist_commentary).reorder("artist_commentaries.updated_at DESC")

        when "artcomm_asc"
          joins(:artist_commentary).reorder("artist_commentaries.updated_at ASC")

        when "mpixels", "mpixels_desc"
          # Use "w*h/1000000", even though "w*h" would give the same result, so this can use the posts_mpixels index.
          joins(:media_asset).reorder(Arel.sql("media_assets.image_width * media_assets.image_height / 1000000.0 DESC"))

        when "mpixels_asc"
          joins(:media_asset).reorder(Arel.sql("media_assets.image_width * media_assets.image_height / 1000000.0 ASC"))

        when "portrait"
          joins(:media_asset).reorder(Arel.sql("media_assets.image_width::numeric / media_assets.image_height::numeric ASC"))

        when "landscape"
          joins(:media_asset).reorder(Arel.sql("media_assets.image_width::numeric / media_assets.image_height::numeric DESC"))

        when "filesize", "filesize_desc"
          joins(:media_asset).reorder("media_assets.file_size DESC")

        when "filesize_asc"
          joins(:media_asset).reorder("media_assets.file_size ASC")

        when /\A(?<column>#{PostQueryBuilder::COUNT_METATAGS.join("|")})(_(?<direction>asc|desc))?\z/i
          column = $~[:column]
          direction = $~[:direction] || "desc"
          reorder(column => direction, :id => direction)

        when "tagcount", "tagcount_desc"
          reorder("posts.tag_count DESC")

        when "tagcount_asc"
          reorder("posts.tag_count ASC")

        when "duration", "duration_desc"
          joins(:media_asset).reorder("media_assets.duration DESC NULLS LAST, posts.id DESC")

        when "duration_asc"
          joins(:media_asset).reorder("media_assets.duration ASC NULLS LAST, posts.id ASC")

        # artags_desc, copytags_desc, chartags_desc, gentags_desc, metatags_desc
        when /(#{TagCategory.short_name_list.join("|")})tags(?:\Z|_desc)/
          reorder("posts.tag_count_#{TagCategory.short_name_mapping[$1]} DESC")

        # artags_asc, copytags_asc, chartags_asc, gentags_asc, metatags_asc
        when /(#{TagCategory.short_name_list.join("|")})tags_asc/
          reorder("posts.tag_count_#{TagCategory.short_name_mapping[$1]} ASC")

        when "random"
          reorder("random()")

        when "rank"
          where("posts.score > 0 and posts.created_at >= ?", 2.days.ago).reorder(Arel.sql("log(3, posts.score) + (extract(epoch from posts.created_at) - extract(epoch from timestamp '2005-05-24')) / 35000 DESC"))

        when "modqueue", "modqueue_desc"
          with_queued_at.reorder("queued_at DESC, posts.id DESC")

        when "modqueue_asc"
          with_queued_at.reorder("queued_at ASC, posts.id ASC")

        when "disapproved", "disapproved_desc"
          group(:id).left_outer_joins(:disapprovals).select("posts.*").select("MAX(post_disapprovals.created_at) AS disapproved_at").reorder("disapproved_at DESC, posts.id DESC")

        when "disapproved_asc"
          group(:id).left_outer_joins(:disapprovals).select("posts.*").select("MAX(post_disapprovals.created_at) AS disapproved_at").reorder("disapproved_at ASC, posts.id ASC")

        when "none"
          reorder(nil)

        else
          reorder("posts.id DESC")
        end
      end

      def tags_include(*tags)
        where_array_includes_all("string_to_array(posts.tag_string, ' ')", tags)
      end

      def raw_tag_match(tag)
        Post.where_array_includes_all("string_to_array(posts.tag_string, ' ')", [tag])
      end

      # Perform a tag search as an anonymous user. No tag limit is enforced.
      def anon_tag_match(query)
        user_tag_match(query, User.anonymous, tag_limit: nil, safe_mode: false)
      end

      # Perform a tag search as the system user, DanbooruBot. The search will
      # have moderator-level permissions. No tag limit is enforced.
      def system_tag_match(query)
        user_tag_match(query, User.system, tag_limit: nil, safe_mode: false)
      end

      # Fork: the posts a BULK RETAG touches -- a BUR mass update, a tag
      # implication -- which is every post the query matches, as upstream's
      # anon_tag_match and system_tag_match gave before this fork added
      # viewer rules to every search. A retag is not a viewer: through the
      # implicit metatags these skipped deleted, gated and prefix-hidden
      # posts, and with creator visibility (2026-10-08) they would have
      # skipped every post a creator narrowed, silently leaving a creator's
      # private posts outside every implication. `user` resolves only what a
      # query itself names (fav:, upvote: and the like), as before.
      def bulk_tag_match(query, user)
        and_relation(PostQuery.normalize(query, current_user: user, tag_limit: nil, safe_mode: false).posts)
      end

      # Perform a tag search as the current user, or as another user.
      #
      # @param query [String] the tag search to perform
      # @param user [User] the user to perform the search as
      # @param tag_limit [Integer] the maximum number of tags allowed per search.
      #   An exception will be raised if the search has too many tags.
      # @param safe_mode [Boolean] if true, automatically add rating:s to the search
      # @return [ActiveRecord::Relation<Post>] the set of resulting posts
      def user_tag_match(query, user = CurrentUser.user, tag_limit: user.tag_query_limit, safe_mode: CurrentUser.safe_mode?)
        post_query = PostQuery.normalize(query, current_user: user, tag_limit: tag_limit, safe_mode: safe_mode)
        post_query.validate_tag_limit!
        posts = post_query.with_implicit_metatags.posts
        and_relation(posts)
      end

      def search(params, current_user)
        params = (params.try(:to_unsafe_h) || params.to_h).with_indifferent_access
        relationship_keys = params.keys.grep(/\A(parent_id(_.+)?|has_parent|has_(active_)?children)\z/)

        # Only allow exact md5 matches for non-moderators (see MediaAsset.search).
        attributes = %i[
          id created_at updated_at rating source pixiv_id fav_count score up_score down_score file_ext
          file_size image_width image_height tag_count is_pending is_flagged is_deleted
          is_banned last_comment_bumped_at last_commented_at last_noted_at uploader approver parent artist_commentary
          flags appeals notes comments children approvals replacements media_metadata
        ]
        attributes += [:md5] if current_user.is_moderator?

        q = search_attributes(params.except(*relationship_keys), attributes, current_user: current_user)
        q = q.relationship_search(params.slice(*relationship_keys), current_user)
        q = q.where(md5: params[:md5].to_s) if params[:md5].present? && !current_user.is_moderator?

        if params[:tags].present?
          q = q.where(id: user_tag_match(params[:tags], current_user).select(:id))
        end

        if params[:order].present?
          q = q.order_matches(params[:order])
        else
          q = q.apply_default_order(params)
        end

        q
      end

      # Fork: search[parent_id*], search[has_parent] and search[has_children]
      # -- from /posts.json and from every nested search[post][...] of a
      # model that belongs to a post -- read a post's relationship as the
      # searcher may be told it, as parent: and child: do. Searchable matched
      # the stored columns, so /comments.json?search[post][parent_id]=<a
      # deleted post> found its visible children's comments where a missing
      # id found none, to anyone, signed out included (2026-11-19). A hidden
      # parent is no parent: its exact id becomes 0, which no post has, and
      # its children are has_parent=false -- and one of the posts whose
      # parent is NOT the one named, as a post with no parent is.
      # search[has_children] read the stored flag AND an EXISTS that
      # Searchable#search_has_include built over posts against itself, which
      # no post satisfied; it reads child_matches now.
      # search[has_active_children] matched the stored flag, which counts a
      # live child hidden from the searcher (boo.122 D2); it asks
      # named_child_sql for a live child they may be told of.
      def relationship_search(params, current_user)
        q = all
        unnamed = Post.unnamed_parent_sql(current_user)
        named = params.slice(*params.keys.grep(/\Aparent_id(_|\z)/)).compact_blank.transform_values { |value| parent_ids_named_to(value, current_user) }

        if named.except(:parent_id_not).present?
          q = q.search_attributes(named.except(:parent_id_not), [:parent_id], current_user: current_user)
          q = q.where.not(unnamed) if unnamed
        end

        if named[:parent_id_not].present?
          matched = Post.unscoped.where_numeric_matches(:parent_id, named[:parent_id_not], :integer)
          matched = matched.where.not(unnamed) if unnamed
          q = q.where.not(id: matched)
        end

        if params[:has_parent].to_s.truthy?
          q = q.parent_matches("any", current_user)
        elsif params[:has_parent].to_s.falsy?
          q = q.parent_matches("none", current_user)
        end

        if params[:has_children].to_s.truthy?
          q = q.child_matches("any", current_user)
        elsif params[:has_children].to_s.falsy?
          q = q.child_matches("none", current_user)
        end

        active = Post.named_child_sql(current_user, undeleted_only: true)
        if params[:has_active_children].to_s.truthy?
          q = q.where(has_active_children: true)
          q = q.where(active) if active
        elsif params[:has_active_children].to_s.falsy?
          q = active ? q.where("posts.has_active_children = FALSE OR NOT (#{active})") : q.where(has_active_children: false)
        end

        q
      end

      # A search[parent_id] value with each exact id of a post hidden from
      # `user` (Post.hidden_ids_among) as 0; anything else (a range, a
      # comparison) as given, which unnamed_parent_sql narrows.
      def parent_ids_named_to(value, user)
        return value unless value.to_s.match?(/\A[\d,\s]+\z/)

        ids = value.to_s.scan(/\d+/).map(&:to_i)
        gone = Post.hidden_ids_among(ids, user)
        ids.map { |id| gone.include?(id) ? 0 : id }.join(",")
      end
    end
  end

  concerning :PixivMethods do
    def parse_pixiv_id
      self.pixiv_id = nil
      self.pixiv_id = parsed_source.work_id if parsed_source.is_a?(Source::URL::Pixiv)
    end
  end

  concerning :RegenerationMethods do
    def regenerate_later!(category, user)
      RegeneratePostJob.perform_later(post: self, category: category, user: user)
    end

    def regenerate!(category, user)
      if category == "iqdb"
        update_iqdb

        ModAction.log("regenerated IQDB for post ##{id}", :post_regenerate_iqdb, subject: self, user: user)
      else
        media_asset.regenerate!

        ModAction.log("regenerated image samples for post ##{id}", :post_regenerate, subject: self, user: user)
      end
    end
  end

  concerning :IqdbMethods do
    def update_iqdb
      # performs IqdbClient.new.add_post(post)
      IqdbAddPostJob.perform_later(self) if IqdbClient.new.enabled?
    end

    def remove_iqdb
      # performs IqdbClient.new.remove(id)
      IqdbRemovePostJob.perform_later(id) if IqdbClient.new.enabled?
    end
  end

  concerning :ValidationMethods do
    # Fork: a new parent the editor may not write to (#writable_by? -- its
    # creator hid it from them, or it is deleted or jailed past what they may
    # see) is a parent that does not exist. Making a post its child wrote
    # onto it, and a hidden id was accepted where a missing one was refused,
    # so walking ids listed the hidden posts (second review, 2026-10-08).
    # Forgotten rather than refused here, so every validation after this one
    # -- the presence check's "post does not exist", the cycle, depth and
    # child-count checks -- answers exactly as it does for a missing id.
    def forget_parent_the_editor_cannot_write
      return unless parent_id.present? && parent_id_changed? && CurrentUser.user.present?
      return if parent.nil? || parent.writable_by?(CurrentUser.user)

      association(:parent).target = nil
    end

    # Walks every post, hidden ones too: a cycle would hang #child_height and
    # every walk after it, so it is refused whoever cannot see the posts it
    # runs through. That refusal is the one answer a hidden relative still
    # shapes, and only by closing a loop through the editor's own post.
    def validate_no_parent_cycles
      return unless parent_id_changed?

      if in?(ancestors)
        errors.add(:base, "Post cannot have itself as a parent")
        throw :abort # Abort to avoid additional error about parent-child chain being more than 4 levels deep
      end
    end

    # The depth and the child count are of the relatives the editor may be
    # told of (#ancestors_shown_to, #child_height_shown_to): counted through
    # hidden posts, the refusal named a hidden chain above or below, or a
    # hidden child at the 30-child edge, that a missing post never does
    # (boo.122 D2). Both limits keep a family readable; neither guards data.
    def validate_parent_depth
      return unless parent_id_changed?

      if parent_hierarchy_depth_shown_to(CurrentUser.user) > MAX_PARENT_DEPTH
        errors.add(:base, "Post cannot have a parent-child chain more than #{MAX_PARENT_DEPTH} levels deep")
      end
    end

    def validate_child_count
      return unless parent_id_changed? && parent.present?

      children = parent.children
      children = children.without_hidden_posts(CurrentUser.user) if CurrentUser.user.present?
      if children.count >= MAX_CHILD_POSTS
        errors.add(:base, "post ##{parent_id} cannot have more than #{MAX_CHILD_POSTS} child posts")
      end
    end

    def uploader_is_not_limited
      if uploader.upload_limit.limited?
        errors.add(:uploader, "have reached your upload limit. Please wait for your pending uploads to be approved before uploading more")
        throw :abort # Don't bother returning other validation errors if we're upload-limited.
      end
    end

    def post_is_not_allowed
      return if uploader.posts.active.exists?

      blocked_tags = Danbooru.config.new_uploader_blocked_ai_tags
      if blocked_tags.present? && ai_tags_match?(blocked_tags)
        errors.add(:base, "Post failed, try again later")
        throw :abort # Don't bother returning other validation errors
      end
    end

    def validate_changed_tags
      return if CurrentUser.user.nil? || uploader == CurrentUser.user || CurrentUser.user.is_builder?

      changed_tags = added_tags + removed_tags

      if RateLimiter.limited?(action: "post:validate_changed_tags", user: CurrentUser.user, cost: changed_tags.size, rate: MAX_CHANGED_TAGS.to_f / MAX_CHANGED_TAGS_INTERVAL, burst: MAX_CHANGED_TAGS, minimum_points: -0.1)
        errors.add(:base, "You can't add or remove more than #{MAX_CHANGED_TAGS.to_i} tags per #{MAX_CHANGED_TAGS_INTERVAL.inspect}. Wait a while and try again")
        throw :abort
      end
    end

    # Creator-prefixed tags (4chan_, 41chan_, aichan_, ... -- the list is
    # config, see CreatorPrefixes) are the post's provenance and its poster.
    # Only an admin, a listed posting service or the system user (approved
    # aliases and implications) may add or remove one. An unreadable list
    # refuses every tag change rather than unlocking anything.
    def validate_creator_prefixed_tags
      user = CurrentUser.user
      return if user.nil? || user.name == Danbooru.config.system_user

      changed = (tag_array - tag_array_was) | (tag_array_was - tag_array)
      return if changed.empty?
      return if CreatorPrefixes.editor?(user)

      locked = changed.select { |name| CreatorPrefixes.locked?(name) }
      return if locked.empty?

      errors.add(:base, "#{locked.sort.join(", ")} #{(locked.size == 1) ? "is a creator tag" : "are creator tags"}: " \
                        "only the posting service or an admin can add or remove #{(locked.size == 1) ? "it" : "them"}. " \
                        "To correct a post's creator, ask an admin (prefixes are listed at /creator_prefixes)")
    rescue CreatorPrefixes::ConfigError => e
      # Fork: words only. What is wrong with the list (a path on the
      # server, an errno, the fix's command) goes to the log: this refusal
      # reaches Technetium's tag editor and the posting bot, which relays a
      # refused edit into a room (technetium-81, 2026-10-19). Logged at
      # :error, which production keeps (Danbooru.config.log_level); every
      # "the server log says what is wrong" refusal logs the same way.
      Rails.logger.error("post ##{id || "(new)"}: tag change paused, the creator-prefix list is broken: #{e.message}")
      errors.add(:base, "Tag changes are paused while the creator-prefix list is broken; the server log says what is wrong. The site owner fixes the list, then try again")
    end

    # A FLAGGED name (TagQuarantine) is added to or removed from a post only
    # by an account that sees flagged posts -- an admin, the system user
    # (approved aliases and implications), a posting bot -- because adding
    # one makes the post vanish for everyone below admin and removing one
    # brings it back. Judged on the whole diff after aliases and
    # implications, so a public tag that implies a flagged one is refused
    # too. The words never name the tag; the refusal does confirm that an
    # exact typed name is flagged, which any refusal must (rate-limited for
    # members below builder by validate_changed_tags).
    def validate_flagged_tags
      flagged = TagQuarantine.flagged_names
      return if flagged.empty?

      user = CurrentUser.user
      return if user.nil? || TagQuarantine.sees_flagged_names?(user)

      changed = (tag_array - tag_array_was) | (tag_array_was - tag_array)
      return if changed.none? { |name| flagged.include?(name) }

      errors.add(:base, "This edit would add or remove a tag only an admin may change. Ask an admin to make it")
    end

    # R2 (operator 2026-11-20): only the jail adds troll_jail, and only the
    # jail takes it off (its release). A hand edit, a revert, a bulk or mass
    # update, an alias or implication that would add or remove it -- any save
    # at all -- is refused with JAIL_TAG_CHANGE_REFUSAL unless the jail makes
    # it: the jail panel's account (Post.jail_tagger?: sampling's tag, delete
    # and release), or one of the booru's own jail acts, which say so with
    # #add_jail_tag! (the banished-tag failsafe, BanishTagJob, the pill's
    # jail-on). Never the system user or a nil one by identity: approved
    # aliases and implications save every matching post as the system user,
    # and that is the path a relationship onto troll_jail would take.
    #
    # Judged after aliases and implications (normalize_tags), on the whole
    # tag string, so a tag that implies troll_jail is refused as well.
    def validate_jail_tag_change
      jail = Danbooru.config.troll_jail_tag
      # Judged against the row, locked, not the copy in memory: a revert, an
      # undo, copy_notes and a duplicate merge save a record loaded earlier,
      # and a jailing in between left it stale -- it held no jail tag, wrote
      # none and "changed" nothing, and the save took the tag off.
      had = if new_record?
        false
      elsif tag_string_changed?
        Post.where(id: id).lock.pick(:tag_string).to_s.split.include?(jail)
      else
        tag_array_was.include?(jail)
      end
      return if tag_array.include?(jail) == had
      return if @jail_tag_by_the_jail || Post.jail_tagger?(CurrentUser.user)

      errors.add(:base, JAIL_TAG_CHANGE_REFUSAL)
    end

    def validate_tag_count
      if tag_array.size > MAX_TAG_COUNT
        errors.add(:base, "Post cannot have more than #{MAX_TAG_COUNT} tags")
      end
    end

    def added_tags_are_valid
      new_tags = added_tags.select(&:empty?)
      new_artist_tags, new_general_tags = new_tags.partition(&:artist?)

      if new_general_tags.present?
        n = new_general_tags.size
        tag_wiki_links = new_general_tags.map { |tag| "[[#{tag.name}]]" }
        warnings.add(:base, "Created #{n} new #{(n == 1) ? "tag" : "tags"}: #{tag_wiki_links.join(", ")}")
      end

      new_artist_tags.each do |tag|
        if tag.artist.blank?
          new_artist_path = Routes.new_artist_path(artist: { name: tag.name })
          warnings.add(:base, "Artist [[#{tag.name}]] requires an artist entry. \"Create new artist entry\":[#{new_artist_path}]")
        end
      end

      post_edit.invalid_added_tags.each do |tag|
        tag.errors.messages.each_value do |messages|
          warnings.add(:base, "Couldn't add tag: #{messages.join(";")}")
        end
      end

      deprecated_tags = post_edit.deprecated_added_tag_names
      if deprecated_tags.present?
        tag_list = deprecated_tags.map { |tag| "[[#{tag}]]" }.to_sentence
        warnings.add(:base, "The following tags are deprecated and could not be added: #{tag_list}")
      end

      # fourier: upstream skips a refused re-file (char:, gen:, ...) in
      # silence. On a claimed original character the refusal is the claim's
      # (TagPolicy), so it is said, naming whose. Asked only for an ask that
      # was not carried out.
      asked = post_edit.tag_categorization_terms.to_h { |term| [::Tag.normalize_name(term.value), ::Tag.categories.value_for(term.name)] }
      refused = asked.empty? ? [] : ::Tag.where(name: asked.keys).reject { |tag| tag.category == asked[tag.name] }.map(&:name)
      CharacterClaim.standing_on(refused).each do |claim|
        warnings.add(:base, "[[#{claim.tag_name}]] is @#{claim.slug}'s original character: its category stays character. Ask an admin.")
      end
    end

    def removed_tags_are_valid
      attempted_removed_tags = post_edit.user_removed_tag_names
      unremoved_tags = tag_array & attempted_removed_tags

      if unremoved_tags.present?
        unremoved_tags_list = unremoved_tags.map { |t| "[[#{t}]]" }.to_sentence
        warnings.add(:base, "#{unremoved_tags_list} could not be removed. Check for implications and try again")
      end
    end

    def has_artist_tag
      return if !new_record?
      return if !web_source?
      return if has_tag?("artist_request") || has_tag?("official_art")
      return if tags.any?(&:artist?)
      return if Source::Extractor.find(source).is_a?(Source::Extractor::Null)

      new_artist_path = Routes.new_artist_path(artist: { source: source })
      warnings.add(:base, "Artist tag is required. \"Create new artist tag\":[#{new_artist_path}]. Ask on the forum if you need naming help")
    end

    def has_copyright_tag
      return if !new_record?
      return if has_tag?("copyright_request") || tags.any?(&:copyright?)

      warnings.add(:base, "Copyright tag is required. Consider adding [[copyright request]] or [[original]]")
    end

    def has_enough_tags
      return if !new_record?

      if tags.count(&:general?) < 10
        warnings.add(:base, "Uploads must have at least 10 general tags. Read [[howto:tag]] for guidelines on tagging your uploads")
      end
    end
  end

  concerning :ArtistCommentaryMethods do
    def remove_blank_artist_commentary
      self.artist_commentary = nil if !artist_commentary&.any_field_present?
    end
  end

  # @param tags [String] The AI tag query.
  delegate :ai_tags_match?, to: :media_asset

  def safeblocked?
    CurrentUser.safe_mode? && (rating != "g" || Danbooru.config.safe_mode_restricted_tags.any? { |tag| tag.in?(tag_array) })
  end

  # Does this post carry a gated tag?
  #
  # "Gated" classifies the CONTENT, not the viewer: the tags in
  # Danbooru.config.restricted_tags mark material this site will not serve
  # casually, so the question has nothing to do with who is asking. Who is
  # asking is what #hidden_as_gated? decides.
  #
  # The list as it stands when asked: a regex built from it when Post loaded
  # kept whatever config was current then, and a Post first loaded under
  # another config gated nothing for the life of the process.
  def gated?
    tag_array.intersect?(Danbooru.config.restricted_tags)
  end

  # Gate 1: a gated post does not exist for a viewer below Gold -- signed
  # out, Restricted or Member (operator, 2026-10-13: "Gate 1 should hide
  # sensitive posts to Restricted and Member the same way it withholds the
  # image") -- unless they uploaded it (the posting bots keep working on
  # their own posts) or its creator let them in (#creator_allows?, gate 9:
  # "the named-creator-allow should control both the post and the image").
  #
  # A different rule from the browsing tier, and deliberately stricter. The
  # tier says "you may see this, but only if you already know where it is";
  # gating says "you may not see this kind of thing at all", which is a
  # statement about the content, and a rule of that shape is not satisfied by
  # withholding the image while still listing the post, its tags and its id.
  # So the post and the image are one answer: #levelblocked? (the image,
  # through #visible?) is this rule.
  #
  # nil counts as signed out: a rule about withholding content has to fail
  # towards withholding, not towards serving. The query-level halves are
  # PostQuery#gated_metatags and the gated term of Post.hidden_from; both
  # read the same allowed set (Post.gated_allowed_ids).
  def hidden_as_gated?(user = CurrentUser.user)
    return false unless gated?
    return true if user.nil? || user.is_anonymous?

    !user.is_gold? && user.id != uploader_id && !creator_allows?(user)
  end

  # A deleted post does not exist, for anyone but its uploader and the people
  # who can undelete it.
  #
  # This is troll jail. A deletion here is not a moderation note on a post that
  # stays reachable -- it is removal from the world's view in one click, and the
  # test of that is whether anything at all still answers: not the page, not the
  # tags, not the id, not an md5 lookup. Upstream's deletion is the softer kind,
  # and the softer kind is not what this button is for.
  #
  # The row is deliberately kept. Holding what was removed is what lets it be
  # used to defend against the next one, and that is a different purpose from
  # the one this project has ruled out for scraped material.
  #
  # The uploader keeps access so an appeal is possible. On 4chan scrapes the
  # uploader is the bot, which is the design working rather than an exception to
  # it -- there, nobody outside admins sees a deleted post at all.
  #
  # And a JAILED or banished-tagged post does not exist for anyone but the
  # pipeline's accounts (hidden_as_banished?, operator 2026-09-24 and
  # 2026-10-12) -- deleted or not. It is answered here, not
  # beside it, because this is the predicate every door already asks -- the
  # post page, its json, the md5 lookup, modulation.json -- and a door added
  # later that asks this one gets both rules without knowing there are two.
  def hidden_as_deleted?(user = CurrentUser.user)
    return true if hidden_as_banished?(user)
    return false unless is_deleted?
    # nil is treated as anonymous, the same way gating treats it: an unknown
    # viewer has to fail towards withholding.
    return true if user.nil?
    return false if user.can_see_deleted_posts?

    (!user.is_anonymous? && uploader_id == user.id) ? false : true
  end

  # A post carrying the jail tag or a banished tag, or jailed without the
  # tag (Post.untagged_jailed_ids), withheld from everyone but the pipeline
  # (TagBanishment.withholds_posts_from?) -- live or deleted, since a
  # released post still carries its banished tag.
  def hidden_as_banished?(user = CurrentUser.user)
    return false unless TagBanishment.withholds_posts_from?(user)

    tag_array.intersect?(TagBanishment.post_tags) || (is_deleted? && Post.untagged_jailed_ids.include?(id))
  end

  # Whether this post does not exist for `user`: deleted/jailed past what they
  # may see, or hidden for any other reason -- the one question a door asks
  # about a post it is about to name.
  def hidden_from?(user = CurrentUser.user)
    hidden_as_deleted?(user) || hidden_beyond_deletion?(user)
  end

  # Every reason this post does not exist for `user` other than deletion:
  # gated from a viewer below Gold (#hidden_as_gated?), under a creator
  # prefix hidden from them, carrying a flagged tag, or hidden by its
  # creator. Split from hidden_from? for the lists whose deleted posts are
  # their own rule (PostPreviewComponent#render?'s show_deleted); everything
  # else asks hidden_from?. Flagged sits here, not beside deletion, so
  # writable_by? never lets a moderator write past it and show_deleted never
  # draws it.
  def hidden_beyond_deletion?(user = CurrentUser.user)
    hidden_as_gated?(user) || hidden_otherwise?(user)
  end

  # hidden_beyond_deletion? less gate 1: what a creator's allow can never
  # open (#creator_allows? asks it, which is why it is split out -- asking
  # hidden_from? there would ask gate 1, and so creator_allows?, again).
  def hidden_otherwise?(user = CurrentUser.user)
    hidden_by_matrix_rooms?(user) || hidden_by_creator_prefix?(user) || hidden_as_flagged?(user) || hidden_by_creator?(user)
  end

  # GATE 3 FOR POSTS (fourier-basis docs/design/GATE3_MATRIX_POSTS.md,
  # operator rulings 2026-10-14/15): a Matrix post is visible to exactly the
  # viewers its image is -- its rooms (posts.room_ids, kept by PostMxc) must
  # meet the viewer's (MatrixViewerRooms: 0 for everyone, -1 for a verified
  # Matrix identity, the rooms they are joined to). Admins are held to it;
  # only the pipeline is spared, and only while gate3_matrix_posts_enforced?
  # is on. A post that is not a Matrix post ({0}) is never asked about the
  # viewer's rooms. No creator's allow opens it, so it sits here.
  #
  # The one exception (operator, 2026-11-01): a post placed on a public
  # creator's page someone opened passes, for every viewer, while the record
  # is fresh (MatrixViewerRooms.placed_grant) -- unless it has no rooms left:
  # redaction still wins (2026-10-15). Every other gate is the viewer's own:
  # the booru decides the rest for their rank (operator, 2026-11-11).
  # Read only once the rooms have said hidden, so every other post costs
  # nothing more.
  #
  # A post loaded without the column (a narrowed select) reads it rather
  # than guess.
  def hidden_by_matrix_rooms?(user = CurrentUser.user)
    return false unless MatrixViewerRooms.enforced_for?(user)

    rooms = has_attribute?(:room_ids) ? room_ids : Post.where(id: id).pick(:room_ids).to_a
    return false if rooms == [MatrixViewerRooms::NOT_MATRIX]
    return false if rooms.intersect?(MatrixViewerRooms.ids(user))

    rooms.empty? || MatrixViewerRooms.placed_grant.exclude?(id)
  end

  # A new Matrix post starts closed ({}): until fourier-auth has answered for
  # its image nobody but the pipeline may see it (fail closed).
  def start_matrix_post_closed
    self.room_ids = [] if source.to_s.start_with?("mxc://")
  end

  # Then its own mxc is mapped to it, which opens it at once to the rooms of
  # an answer already pushed for that mxc (PostMxc.record_post_source!).
  def record_post_mxc
    PostMxc.record_post_source!(self) if source.to_s.start_with?("mxc://")
  end

  # A post carrying a FLAGGED tag (TagQuarantine, operator rulings
  # 2026-10-12): gone for everyone but Admin level and up and the system user
  # -- and a posting bot on a post it uploaded itself. Read from tag_string,
  # so a post that gains the tag later is gone at once, and a release brings
  # it back at once.
  def hidden_as_flagged?(user = CurrentUser.user)
    flagged = TagQuarantine.flagged_names
    return false if flagged.empty? || tag_array.none? { |t| flagged.include?(t) }

    case TagQuarantine.flagged_posts_visible_to(user)
    when :all then false
    when :own then uploader_id != user.id
    else true
    end
  end

  # Hidden by its creator's panel (CreatorVisibility; design
  # CREATOR_VISIBILITY sections 4-9, ruled 2026-10-07): private, groups-only
  # or a block, for a viewer the creator did not let in. Exactly what gate 1
  # means for a signed-out visitor -- the post does not exist (section 6).
  # Read from a set computed once per request per viewer, never per post.
  def hidden_by_creator?(user = CurrentUser.user)
    CreatorVisibility.hidden_ids(user).include?(id)
  end

  # Let past gate 1 by its creator (section 7, Q1: "a creator can widen"):
  # an explicit group or named allow, or being the controller -- to the post
  # AND its image (operator, 2026-10-13). Never for a signed-out or banned
  # viewer, or a jailed post (CreatorVisibility step 4); never past an
  # unreleased hidden prefix (the release precondition, section 7). Asked by
  # #hidden_as_gated? alone.
  #
  # And never for a post that does not exist for the viewer anyway (deleted,
  # jailed or flagged, under ANOTHER creator's hidden prefix, hidden by a
  # creator): a widen lifts gate 1 and nothing else, so a door that asks only
  # #visible? -- can_see_media? on a nested post -- must not be handed what
  # every other door refuses (fourier-sampling-c2's check c, 2026-10-08).
  # Those reasons are asked one by one, never as hidden_from?, which asks
  # gate 1 and so this method again. Asked only of a post in the set, so the
  # rest pay nothing.
  def creator_allows?(user = CurrentUser.user)
    CreatorVisibility.widened_ids(user).include?(id) && !hidden_as_deleted?(user) && !hidden_otherwise?(user)
  end

  # The gated posts gate 1 lets `user` see although they are below Gold:
  # those their creator let them past (CreatorVisibility.widened_ids) and
  # those they uploaded themselves -- the id set PostQuery#gated_metatags
  # and Post.hidden_from exempt, as #hidden_as_gated? does one post at a
  # time. Their uploads are found here, by the uploader_id index (nothing,
  # for an account that uploads nothing), rather than by a user: term in the
  # query, which would make every member's count cache per user. Empty for
  # a signed-out viewer, and for Gold and up, whom gate 1 does not hold back
  # at all. Once per request.
  def self.gated_allowed_ids(user)
    return Set.new if user.nil? || user.is_anonymous? || user.is_gold? || Danbooru.config.restricted_tags.blank?

    CreatorVisibility.memoized(:gated_allowed, user) do
      own = where(uploader_id: user.id).where_array_includes_any("string_to_array(posts.tag_string, ' ')", Danbooru.config.restricted_tags).pluck(:id)
      CreatorVisibility.widened_ids(user) | own
    end
  end

  # gated_allowed_ids as the '{1,2,3}' literal an integer[] parameter binds,
  # or nil when there are none -- built once per request.
  def self.gated_allowed_ids_literal(user)
    return nil if user.nil? || user.is_anonymous? || user.is_gold?

    CreatorVisibility.memoized(:gated_allowed_literal, user) do
      ids = gated_allowed_ids(user)
      ids.empty? ? nil : "{#{ids.sort.join(",")}}"
    end
  end

  # A post carrying a creator tag whose prefix the list hides from `user`
  # (CreatorPrefixes, visible_to). Operator, 2026-10-07: aichan_ admins only.
  def hidden_by_creator_prefix?(user = CurrentUser.user)
    ctx = CreatorPrefixes.hidden_context(user)
    return false if ctx[:prefixes].empty?

    tag_array.any? { |t| CreatorPrefixes.hidden_for?(t, user, ctx) }
  end

  # The same rule for a SET of posts: the posts hidden_from? is true of, as a
  # relation -- or nil when nothing is hidden from `user`, so a caller can
  # skip the filter rather than run an empty one.
  #
  # WHY A RELATION (2026-10-01). The post's own doors asked hidden_from? one
  # post at a time and were shut; every other record that NAMES a post was
  # not. A leak audit read jailed post 413157 anonymously through
  # /post_versions (its whole tag history and 4chan source), the artist
  # commentary ("Posted by X in /trash/ thread N"), flags and the mod log
  # ("troll jail: shock"), post events, favorites, /counts (id:N answered 1)
  # and IQDB matches -- while /posts/413157.json was a 404. A listing cannot
  # ask a predicate per row without breaking its own count and paginator, so
  # the rule has to exist as SQL. ApplicationRecord.without_hidden_posts
  # applies it to every model that belongs_to a post, from paginated_search,
  # and ApplicationController#authorize asks hidden_from? of a single record
  # -- so a door added later gets the rule without knowing there is one.
  #
  # Must agree with hidden_from? row for row; hidden_post_doors_test holds
  # both to the same fixtures.
  #
  # by_creator: false leaves out the creator term, for a caller that holds
  # the ids already and checks them in Ruby (hidden_ids_among). rooms: false
  # leaves out Gate 3's, for the one question asked of every gate but it --
  # what the media door refuses a room member (MediaDoorAsk.withheld_ids).
  def self.hidden_from(user, by_creator: true, rooms: true)
    tags = "string_to_array(posts.tag_string, ' ')"
    terms = []
    # The tag names that hide a post whoever uploaded it, as ONE overlap:
    # Postgres splits tag_string once per term, and a listing that visits
    # every post paid for each split -- /user_actions of a posting bot
    # (400,000 posts on the dev DB, 2026-10-14) took 1.4 s with one split and
    # 4.2 s with two, past a member's 3 s statement timeout.
    names = []

    # Gate 1 (#hidden_as_gated?): gated posts, below Gold, less the viewer's
    # own uploads and the posts a creator let them past (gated_allowed_ids,
    # which holds both) -- a row filter, so the NOT IN is over the viewer's
    # own allowed set, never over the gated posts (see
    # ApplicationRecord.without_hidden_posts).
    if Danbooru.config.restricted_tags.present? && !(user.present? && user.is_gold?)
      allowed = gated_allowed_ids_literal(user)
      if allowed
        terms << where_array_includes_any(tags, Danbooru.config.restricted_tags).where("posts.id NOT IN (SELECT unnest(?::integer[]))", allowed)
      else
        names += Danbooru.config.restricted_tags
      end
    end

    names += TagBanishment.post_tags.to_a if TagBanishment.withholds_posts_from?(user)

    # Flagged (#hidden_as_flagged?): by name, with the bot's own uploads
    # excepted. Nothing flagged adds nothing.
    flagged = TagQuarantine.flagged_names
    if flagged.any?
      case TagQuarantine.flagged_posts_visible_to(user)
      when :none then names += flagged.to_a
      when :own then terms << where_array_includes_any(tags, flagged.to_a).where.not(uploader_id: user.id)
      end
    end

    names += CreatorPrefixes.hidden_tag_names_for(user)
    terms << where_array_includes_any(tags, names.uniq) if names.any?

    # Gate 3 for posts (#hidden_by_matrix_rooms?): the rooms do not meet the
    # viewer's, as one row filter with the viewer's set inlined (see
    # MatrixViewerRooms.literal) -- nor, signed out, is the post placed on a
    # public creator's page with rooms left (MatrixViewerRooms.condition,
    # operator 2026-11-01). room_ids is NOT NULL, so the inversion
    # without_hidden_posts makes of it is exact.
    terms << where("NOT (#{MatrixViewerRooms.condition(user)})") if rooms && MatrixViewerRooms.enforced_for?(user)

    # By id, as PostQuery#hidden_post_metatags excludes them -- one array
    # literal, unnested, for the reasons Searchable#attribute_matches gives
    # (a quoted IN list is slow to render; `= ANY(array)` as a row filter is
    # a linear scan of the list for every row).
    literal = CreatorVisibility.hidden_ids_literal(user) if by_creator
    terms << where("posts.id IN (SELECT unnest(?::integer[]))", literal) if literal

    # The banished names are in `names` above, one split for every name.
    deleted = hidden_as_deleted_sql(user)
    terms << where(deleted) if deleted

    terms.reduce(:or)
  end

  # The deletion half of #hidden_as_deleted? as SQL, for Post.hidden_from,
  # which holds the banished names with the rest of its names: a post jailed
  # without the tag (Post.untagged_jailed_ids), and a deletion past what
  # `user` may see. nil when neither applies -- the pipeline, or an admin
  # with nothing jailed untagged. Every column read is NOT NULL, so NOT of
  # it is exact.
  def self.hidden_as_deleted_sql(user)
    terms = []
    if TagBanishment.withholds_posts_from?(user)
      jailed = untagged_jailed_ids
      terms << sanitize_sql_array(["(posts.is_deleted = TRUE AND posts.id IN (SELECT unnest(?::integer[])))", "{#{jailed.sort.join(",")}}"]) if jailed.any?
    end
    unless user.present? && user.can_see_deleted_posts?
      sql = "posts.is_deleted = TRUE"
      sql += " AND posts.uploader_id <> #{user.id.to_i}" unless user.nil? || user.is_anonymous?
      terms << "(#{sql})"
    end
    "(#{terms.join(" OR ")})" if terms.any?
  end

  # A post hidden from `user` (Post.hidden_from, the whole rule) whose id is
  # `ref`, a column of the row outside -- "posts.parent_id",
  # "post_versions.parent_id" -- as one correlated EXISTS; nil when nothing
  # is hidden from them. The relative is a second copy of posts, so the
  # outer row's column is carried in through a one-row derived table (rel)
  # and hidden_from is used exactly as it is built: its terms say `posts`,
  # and there `posts` is the relative. Postgres reads the one relative by
  # its primary key per row (EXPLAIN on production, 2026-11-20).
  #
  # boo.122 D2 (2026-11-20): the relationship searches asked only the
  # DELETION half (hidden_as_deleted_sql), so an admin's parent:any and
  # child:any matched through a jailed relative, a jailed post's uploader
  # through their own, and a member through every live hidden relative --
  # a released banished name, a creator-hidden, flagged, gated, prefix or
  # rooms post. One rule, one definition: a term added to hidden_from is in
  # every relationship search the day it is added.
  def self.hidden_relative_sql(user, ref)
    hidden = unscoped { hidden_from(user) }
    return nil if hidden.nil?

    relative = unscoped.merge(hidden).where("posts.id = rel.id").select("1").to_sql
    "EXISTS (SELECT 1 FROM (SELECT #{ref} AS id) rel WHERE EXISTS (#{relative}))"
  end

  # A post whose parent is hidden from `user` (Post.hidden_relative_sql) --
  # a post that, to them, has no parent (#parent_id_shown_to); nil when
  # nothing is hidden from them. parent:none, parent:any and
  # search[has_parent] ask it, so a hidden parent's id is answered as a
  # missing one's (2026-11-19, the whole rule since boo.122 D2).
  def self.unnamed_parent_sql(user)
    hidden = hidden_relative_sql(user, "posts.parent_id")
    "(posts.parent_id IS NOT NULL AND #{hidden})" if hidden
  end

  # A post with a child `user` may be told of (#children_shown_to), among
  # `among` if given, and only a live child if `undeleted_only`; nil when
  # nothing is hidden from them, for whom the stored flags are the answer.
  # The flags count a hidden child, so child:any found a visible post whose
  # only child was deleted (2026-11-19) or jailed, and
  # search[has_active_children] one whose only live child its creator hid
  # (boo.122 D2). Correlated as Post.hidden_relative_sql is: the children
  # are read by index_posts_on_parent_id, and without_hidden_posts is the
  # whole rule inverted.
  def self.named_child_sql(user, among = nil, undeleted_only: false)
    return nil if unscoped { hidden_from(user) }.nil?

    visible = unscoped.where("posts.parent_id = rel.id").without_hidden_posts(user)
    visible = visible.where(is_deleted: false) if undeleted_only
    visible = visible.where(id: among.select(:id)) if among
    "EXISTS (SELECT 1 FROM (SELECT posts.id AS id) rel WHERE EXISTS (#{visible.select("1").to_sql}))"
  end

  # ApplicationRecord.without_hidden_posts, for posts themselves: the posts
  # hidden_from is not true of. For a listing of posts built without
  # PostQuery's implicit metatags -- /user_actions listed every post its
  # creator hid, by id and arrival time (second review, 2026-10-08).
  # Inverted rather than NOT IN the hidden set, so Postgres checks only the
  # rows the listing visits (the 9-11 s NOT IN that
  # ApplicationRecord.without_hidden_posts describes). Every column the
  # terms read is NOT NULL, so the inversion is exact. Built unscoped, or the
  # caller's own conditions would be inverted with it.
  def self.without_hidden_posts(user)
    hidden = unscoped { hidden_from(user) }
    hidden.nil? ? all : self.and(hidden.invert_where)
  end

  # Post.find for a door that names a post on the caller's behalf: a hidden
  # post is "not found", exactly as a missing one is, so the answer cannot be
  # used to tell them apart.
  def self.find_visible!(id, user = CurrentUser.user)
    post = find(id)
    raise ActiveRecord::RecordNotFound if post.hidden_from?(user)

    post
  end

  # Post.find for a door that WRITES to a post (PostsController#update and
  # its siblings): a post not #writable_by? the writer is "not found".
  def self.find_writable!(id, user = CurrentUser.user)
    post = find(id)
    raise ActiveRecord::RecordNotFound unless post.writable_by?(user)

    post
  end

  # May `user` write to this post -- edit, delete, undelete, ban or
  # regenerate it, or file a row on it (a favorite, a vote, a comment, a note,
  # a flag, an approval)? Not when it is hidden from them: the write is
  # refused as not found, like the read (R1, operator 2026-11-20). A write
  # answers with the whole post, so a write past hidden_from? was a read past
  # it.
  #
  # One exception: the pipeline's approver (TagBanishment.pipeline? -- sample,
  # which jails and deletes posts it cannot see) writes a post hidden from it
  # only as DELETED or JAILED, never past #hidden_beyond_deletion? (a
  # creator's narrowing, a hidden prefix, a flagged tag). An admin who sees
  # deleted posts is not hidden from them and writes them as anyone writes a
  # post they can see; a jailed post is hidden from an admin and refused like
  # any other. ApplicationController#authorize asks this of every record a
  # write names (#refuses_write_from?), so a write door added later is
  # covered without knowing (review, 2026-10-08: favorites, votes and
  # comments were not).
  def writable_by?(user = CurrentUser.user)
    return true unless hidden_from?(user)

    user.present? && user.is_approver? && TagBanishment.pipeline?(user) && !hidden_beyond_deletion?(user)
  end

  # ApplicationRecord#refuses_write_from?, for the post itself. A post not
  # yet saved is an upload, which the upload rules decide.
  def refuses_write_from?(user)
    persisted? && !writable_by?(user)
  end

  # The parent, siblings and children a post's relationship notices name to
  # `viewer` -- the post page and the Modulation payload, which must say the
  # same (review, 2026-10-08). A post that does not exist for the viewer
  # (#hidden_beyond_deletion?: hidden by its creator, under a hidden creator
  # prefix, gated from a viewer below Gold) is neither counted nor linked;
  # deleted ones keep upstream's rule: shown when this post or its parent is
  # deleted, or the viewer asked to see deleted children.
  #
  # Siblings and children are lists, so below full browsing each is its
  # first page, User#listing_per_page_limit (ACCOUNT_LIMITS.md 2.3). The
  # parent is one hop within a family, not a walk, and stays.
  #
  # @return [Hash{Symbol => Object}] parent: a Post or nil; siblings: and
  #   children: Arrays of Post
  def relatives_shown_to(viewer)
    shown_parent = parent unless parent.nil? || parent.hidden_from?(viewer)
    include_deleted = is_deleted? || shown_parent&.is_deleted? || viewer.show_deleted_children?
    shown = lambda do |posts|
      found = (include_deleted ? posts : posts.undeleted).includes(:media_asset).reject { |post| post.hidden_from?(viewer) }
      viewer.can_browse_freely? ? found : found.first(viewer.listing_per_page_limit)
    end

    { parent: shown_parent, siblings: shown_parent.nil? ? [] : shown.call(shown_parent.children), children: shown.call(children) }
  end

  # `ids` without the posts hidden from `user` (Post.hidden_from), in their
  # own order -- for a record that holds a LIST of post ids rather than a
  # post column (a pool, a favorite group), whose ids the listing rule of
  # ApplicationRecord.without_hidden_posts cannot reach. One query.
  def self.visible_ids_among(ids, user = CurrentUser.user)
    gone = hidden_ids_among(ids, user)
    gone.empty? ? ids : ids.reject { |id| gone.include?(id) }
  end

  # The ids among `ids` of posts hidden from `user`, as a Set, in one query
  # -- what a page of pools, favorite groups or pool versions asks ONCE for
  # all its rows (PostIdList.preload_visible_post_ids), not once a row. The
  # creator-hidden ones are read from the per-request set in memory, not
  # sent back to the database as a list of every hidden id (measured,
  # 2026-10-08: ~200 ms of a 1,000-pool page).
  def self.hidden_ids_among(ids, user = CurrentUser.user, rooms: true)
    return Set.new if ids.empty?

    by_creator = CreatorVisibility.hidden_ids(user) & ids
    hidden = hidden_from(user, by_creator: false, rooms: rooms)
    hidden.nil? ? by_creator : by_creator | where(id: ids.uniq).and(hidden).pluck(:id)
  end

  # A search of a record that holds a LIST of post ids (Pool, FavoriteGroup,
  # PoolVersion) BY those ids -- search[post_ids_include_any]=N, its
  # siblings, a version's added_/removed_ ones and search[post_id] -- asks
  # about the posts that exist for `user`. The stored lists are whole, so a
  # hidden id matched the pools and versions holding it, confirming the post
  # exists, where and since when (reviews, 2026-10-08). A hidden id becomes
  # 0, which no post has, so it matches no list, as a missing post's id
  # does. A regex over the ids cannot be held to what the searcher may see,
  # so it is refused.
  def self.searchable_post_id_params(params, user = CurrentUser.user)
    params = (params.try(:to_unsafe_h) || params).with_indifferent_access
    regex = params.keys.grep(/\Aany_((added|removed)_)?post_id_matches_regex\z/).find { |key| params[key].present? }
    raise ActionController::BadRequest, "search[#{regex}] is refused here: it would match posts hidden from you. Search with post_ids_include_any instead." if regex

    # And search[post_id_count] (Searchable's #{singular}_count), which
    # counted the stored list -- the deleted posts in it included, so a pool
    # whose visible posts numbered one matched post_id_count=3 (2026-11-19).
    # Refused only where something is hidden from `user`; the count is
    # exact for everyone else.
    count = params.keys.grep(/\A((added|removed)_)?post_id_count\z/).find { |key| params[key].present? }
    raise ActionController::BadRequest, "search[#{count}] is refused here: it would count posts hidden from you. Search with post_ids_include_any, or order by post_count." if count && !unscoped { hidden_from(user) }.nil?

    keys = params.keys.grep(/\A((added|removed)_)?post_ids_include_(any|all)(_lower)?(_array)?\z/)
    keys << "post_id" if params[:post_id].present?
    return params if keys.empty?

    asked = keys.index_with { |key| Array.wrap(params[key]).flat_map { |value| value.to_s.scan(/[^[:space:]]+/) }.map(&:to_i) }
    gone = hidden_ids_among(asked.values.flatten, user)
    params.merge(asked.to_h do |key, ids|
      ids = ids.map { |id| gone.include?(id) ? 0 : id }
      [key, key.end_with?("_array") ? ids : ids.join(" ")]
    end)
  end

  # The number of the posts in `column` (an integer[] of post ids, as SQL)
  # that `user` may see, as an SQL expression -- what a pool or a favorite
  # group orders by for order=post_count. cardinality(column) counted the
  # deleted posts in the list too, so the order ranked a pool by posts the
  # searcher could not see (2026-11-19). The bare cardinality when nothing
  # is hidden from them.
  def self.visible_count_sql(column, user)
    return "cardinality(#{column})" if unscoped { hidden_from(user) }.nil?

    "(#{unscoped.where("posts.id = ANY(#{column})").without_hidden_posts(user).select("COUNT(*)").to_sql})"
  end

  # Whether an upload of this post's file by `user` is REFUSED, rather than
  # merged into this post and redirected to it (PostsController#create).
  #
  # Upstream answers a taken md5 by merging the uploader's tags and rating
  # into the post that holds the file and redirecting to it. Found 2026-10-02
  # from fourier-tunnel's logs: the tunnel uploaded the files of deleted posts
  # 22, 25 and 164076 (jailed), each create merged its tags into the deleted
  # post, and each answered 302 to /posts/<id> -- the id of a post that
  # answers nothing anywhere else.
  #
  # Refused when the post is hidden from the uploader (#hidden_from?), and
  # ALSO when it is deleted and the uploader cannot see deleted posts -- its
  # own uploader included. The uploader's exemption in #hidden_as_deleted? is
  # a READ, kept so an appeal is possible; tagging a removed post by
  # uploading its file again is not an appeal. The tunnel had uploaded all
  # three of those posts itself, so #hidden_from? alone would have left the
  # observed case exactly as it was. An account that can see deleted posts
  # (an admin, and the pipeline for a jailed one) keeps upstream's
  # merge and redirect.
  def refuses_duplicate_upload_from?(user = CurrentUser.user)
    hidden_from?(user) || (is_deleted? && (user.nil? || !user.can_see_deleted_posts?))
  end

  # THE BOORU'S OWN JAIL (2026-09-24). A live post that GAINS a banished tag
  # (TagBanishment.list, the database list) is jailed in the same transaction: the
  # jail tag added, then the post deleted -- the end state fourier-sampling's
  # jailSync.ts produces, in its order, with the reason "troll jail: banished
  # tag". The reason does not NAME the tag: a deletion flag's reason and the
  # mod log are read by anyone at /post_flags and /mod_actions, signed in or
  # not, and a banished name is shown to nobody but the pipeline
  # (TagBanishment). The post's own tags say which, to whoever may see them.
  #
  # Until this, jailing was something only a client did, so it happened only
  # when that client was looking. Measured on production the day this was
  # written: five posts sampling had jailed were live, because the jail
  # landed seconds before the poster created the post and nothing looked
  # again. A callback on the save is the one place every door passes through
  # -- API and form edits, the retag bot, the tunnel, uploads, implications,
  # alias moves, reverts. update_columns and raw SQL do not pass through it,
  # and nothing in this app writes tags that way.
  #
  # GAINS, not CARRIES. Releasing a jailed post takes troll_jail off and
  # leaves the banished tag on, on purpose; a rule keyed on carrying would
  # put it straight back. So only a banished tag a save ADDED fires, and a
  # post that is deleted by the time the save finishes is left alone.
  #
  # And a RELEASE IS FINAL against this pass (review, 2026-09-24). A human
  # who released a jailing has decided about that image, and sampling's
  # jailPolicy keeps such md5s `exempt`: "never auto-jailed again, whatever
  # the rules say". This is an automatic pass as well, and the retag timer
  # pushes hydra's tags onto released posts without consulting that list,
  # so without this a released post that gained a second banished name was
  # jailed again here, undoing the release where sampling never would. A
  # human can still jail it by hand. What proves a release is
  # released_from_jail?, and it is never the words on a flag (boo.122 C3).
  #
  # Noted before the save, acted on after it, because the tag diff is only
  # exact before the write -- after_save callbacks that save again
  # (apply_post_metatags) replace saved_changes. Noted by OR-ing in, because
  # those nested saves run this hook too and must not erase what the outer
  # save found.
  concerning :BanishedTagJailMethods do
    private

    def note_banished_tags_gained
      banished = TagBanishment.list
      return if banished.empty?

      gained = (tag_array - (new_record? ? [] : tag_array_was)) & banished
      @banished_tags_gained = @banished_tags_gained.to_a | gained if gained.any?
    end

    # Tag first, then delete, as the booru's system user: the editor added a
    # tag, the booru did the jailing, and the version history and mod log say
    # exactly that. No loop: the jail tag is not banished, and deleting
    # changes no tags. No double jailing: a post already carrying troll_jail
    # keeps one, and a deleted post is never reached.
    #
    # Deleted is asked of the DATABASE as well as of this copy (boo.122 C4):
    # another request can delete the post between this request's load and its
    # save, and the stale copy would jail it on top of that deletion. The read
    # is exact: this save's own UPDATE holds the post's row lock until commit,
    # so a deletion that committed first is seen here, and a later one waits
    # on the lock (Post#delete! takes it). No reload, which would throw away
    # the copy the caller goes on to render.
    def jail_on_banished_tags
      gained = @banished_tags_gained
      @banished_tags_gained = nil
      return if gained.blank? || is_deleted? || Post.where(id: id).pick(:is_deleted) || released_from_jail?

      reason = "troll jail: banished tag" # why, never which: see above
      # The editor's view of the edit (old_tag_string and friends) is spent;
      # the saves below are the booru's own and must not be merged against it.
      self.old_tag_string = self.old_rating = self.old_source = self.old_parent_id = nil
      # safe_mode off as well: a deletion flag refuses a post its creator
      # cannot see, and the system user must see every post.
      CurrentUser.set(user: User.system, safe_mode: false) { add_jail_tag! }
      jail_by_booru!(reason)
    end

    # RELEASED = the jail deleted it (Post.jail_deletions: proved by the
    # account that acted, under the name it held then or holds now, never by
    # the words) and an undeletion was logged after that. Every ordinary
    # undelete door refuses a post whose standing deletion is the jail's
    # (PostApproval, the pill, Post#jailed?), so since 2026-10-10 that
    # undeletion is the release route's (FourierJailController#release!);
    # before then it was a human's approval, a release as well. A flag's
    # words prove nothing: any member can type "troll jail" into a flag,
    # which Post#delete! then marks succeeded, and any approver into a
    # deletion reason (boo.122 C3). A post a moderator merely undeleted is
    # still jailed when it gains a banished tag. Asked only when a banished
    # tag was gained, so the queries are off every ordinary save.
    def released_from_jail?
      first_jailing = Post.jail_deletions.where(subject_id: id).minimum(:id)
      return false if first_jailing.nil?

      ModAction.where(subject: self, category: :post_undelete).exists?(["id > ?", first_jailing])
    end
  end

  # WHAT A JAILING IS, ON THE BOORU, and the one door out of it.
  #
  # Operator ruling 2026-10-10: "Jailed means deleted." A jailed post is a
  # DELETED post carrying troll_jail, and it is withheld exactly as every
  # deleted post is (#hidden_as_deleted?, deleted_post_visibility_level) --
  # nothing here decides who may SEE one. What this concern decides is who
  # may UNDO one: operator ruling 2026-10-09, there is no booru-side way to
  # release a jailed post; release happens only from the jail panel, as
  # POST /fourier_jail/release by the jail's account. So every ordinary
  # undelete door (PostApproval, the post-page pill) asks #jailed? and
  # refuses with JAILED_RELEASE_DOOR.
  #
  # WHO PROVES THE JAIL ACTED. The jail's deletions are told apart by the
  # account that made them, read from the post_delete mod action only code
  # writes, never by the reason text: DELETE /posts/:id takes any approver's
  # free text, so "troll jail: radioactive" typed by an approver would
  # otherwise be a legal hold nothing could release, and "troll jail: x" a
  # moderator's deletion the panel could undo. The jail's accounts are
  # sampling's (fourier_jail_release_names, fourier_posting_bot_names) and the
  # booru's own system user, which the banished-tag failsafe and the pill's
  # jail-on delete as (#jail_by_booru!).
  JAIL_DELETION_REASON = "troll jail: "
  # The mod action categories #jailed? reads (#deletion_is_the_jails?,
  # #jailing_stands?), and so the ones that move Post.untagged_jailed_ids.
  JAIL_LOG_CATEGORIES = %w[post_delete post_undelete post_jail post_unjail].freeze
  # Changed after every commit that moves Post.untagged_jailed_ids, so the
  # shared cache entry keyed on it is never read again (Post.jail_state_changed!).
  UNTAGGED_JAILED_EPOCH_KEY = "post/untagged-jailed/epoch"
  # A legal hold is never released (operator ruling 2026-10-08).
  LEGAL_HOLD_REASON = "troll jail: radioactive"
  JAILED_RELEASE_DOOR = "this post is jailed: a jailed post is released only from the jail panel (fourier-sampling), never from the booru"
  # Said beside JAILED_RELEASE_DOOR for a jailing from before the booru
  # reported its jailings (2026-10-10), which the panel has no row for.
  # The post page's jail switch, turned off on a live post that carries
  # troll_jail: not jailed (Post#jailed? needs a deletion), so not the
  # jailed door's words; only the jail takes the tag off (R2).
  JAIL_TAG_ON_LIVE_POST = "this post is not jailed but carries troll_jail, which only the jail adds and takes off: the jail panel's release removes it"
  # Post#validate_jail_tag_change's refusal (R2, operator 2026-11-20).
  JAIL_TAG_CHANGE_REFUSAL = "troll_jail is added and taken off only by the jail. To jail this post use the jail panel (fourier-sampling), the jail switch on the post page, or banish a tag it carries; a jailed post is released from the jail panel alone"
  UNREPORTED_JAILING = "the jail panel has not been told of this jailing yet: an admin runs script/fourier_report_past_jailings.rb (a dry run first, then -- --apply), after which it is unjailed from the panel"

  concerning :TrollJailMethods do
    class_methods do
      # The jail panel's account, which tags, deletes and releases posts for
      # the jail: an approver named in fourier_jail_release_names, the same
      # test as FourierJailController#jail_panel_only!. Not the posting bots
      # or the system user, which jail_account_names also holds: neither
      # writes the tag by hand (the booru's own jail acts use #add_jail_tag!).
      def jail_tagger?(user)
        return false if user.nil? || !user.is_approver?

        Array(Danbooru.config.fourier_jail_release_names).map { |name| name.to_s.strip.downcase }.include?(user.name.to_s.downcase)
      end

      def jail_account_names
        names = Array(Danbooru.config.fourier_jail_release_names) + Array(Danbooru.config.fourier_posting_bot_names) + [Danbooru.config.system_user]
        names.map { |name| name.to_s.strip.downcase }.compact_blank.uniq
      end

      # The post_delete mod actions a jail account wrote, with a reason that
      # starts `reason`. The account is a jail account if the name its
      # creator held WHEN IT ACTED is on the list, or the name it holds now:
      #
      #   - when it acted: a rename of 'sample' away (allowed to the site
      #     owner) must not release every jailing and hold it wrote.
      #     update_name! is the only writer of users.name after signup and
      #     every rename leaves a UserNameChangeRequest, so the name held at
      #     a moment is the original_name of the first rename after it, or
      #     the name now;
      #   - now: the jail's own account renamed ONTO the list keeps what it
      #     did before. Measured on production 2026-10-10 (read-only): user 6
      #     was renamed sampling -> sample on 2026-09-14, and every jailing
      #     it made before that -- the early-September ones -- was written
      #     under 'sampling'. Judged by the old name alone, each would be
      #     "not the jail's": release would lift only its tag and leave it
      #     deleted for good.
      #
      # Either way it is an account, never words: an approver who is not a
      # jail account, then or now, proves nothing by typing "troll jail: ".
      def jail_deletions(reason = JAIL_DELETION_REASON)
        held_name = <<~SQL.squish
          lower(COALESCE(
            (SELECT renamed.original_name FROM user_name_change_requests renamed
              WHERE renamed.user_id = mod_actions.creator_id AND renamed.created_at > mod_actions.created_at
              ORDER BY renamed.created_at, renamed.id LIMIT 1),
            (SELECT actor.name FROM users actor WHERE actor.id = mod_actions.creator_id)))
        SQL
        name_now = "(SELECT lower(actor.name) FROM users actor WHERE actor.id = mod_actions.creator_id)"
        names = jail_account_names
        ModAction.where(category: :post_delete, subject_type: "Post")
                 .where("#{held_name} IN (:names) OR #{name_now} IN (:names)", names: names)
                 .where("mod_actions.description LIKE ('deleted post #' || mod_actions.subject_id || ', reason: ' || ?)", "#{sanitize_sql_like(reason)}%")
      end

      # The posts #jailed? is true of that do not carry troll_jail, by id
      # (boo.122 D3, 2026-11-20). Every hidden term asked the TAG
      # (TagBanishment.post_tags), but #jailed? also reads the log: a post
      # the jail deleted, or whose jailing the booru reported, is jailed with
      # the tag gone. 429 production posts were so, and each was shown to an
      # admin -- its page, its json, status:deleted, its card, a child's
      # parent and the Matrix door's document. Each of those now adds this
      # set (#hidden_as_banished?, Post.hidden_as_deleted_sql,
      # PostQuery#hidden_post_metatags, TagQuarantine.document).
      #
      # The set costs 180-630 ms on production (measured uncached
      # 2026-11-20), so it is computed once per change, not per request:
      # cached under a fingerprint of everything it reads that a write can
      # move (#untagged_jailed_fingerprint), and once per request in memory.
      def untagged_jailed_ids
        CreatorVisibility.memoized(:untagged_jailed, nil) do
          single_flight_fetch("post/untagged-jailed/#{untagged_jailed_fingerprint}") { untagged_jailed_ids_now }.to_set
        end
      end

      # Every post the jail withholds from everyone but the pipeline, by id:
      # each post carrying the jail tag or a banished tag, deleted or not
      # (TagBanishment.post_tags, Post#hidden_as_banished?), and each post
      # jailed without the tag. For the tag names withheld with them (R3,
      # 2026-11-20: CreatorVisibility.name_hiding_ids). A live post carrying
      # the tag is not jailed (R2), but it is withheld, and a name it alone
      # carries was listed while a flagged tag's posts already hid theirs.
      # Kept as untagged_jailed_ids is: a change to those tags or to a
      # deletion announces itself after commit (#announce_jail_state_change),
      # and the key carries the banished list, which a banish moves.
      def withheld_by_jail_ids
        CreatorVisibility.memoized(:jailed, nil) do
          tags = TagBanishment.post_tags.sort
          single_flight_fetch("post/jail-withheld/#{untagged_jailed_fingerprint}/#{Digest::SHA256.hexdigest(tags.to_json).first(16)}") do
            tagged = where_array_includes_any("string_to_array(posts.tag_string, ' ')", tags).pluck(:id)
            (tagged | untagged_jailed_ids.to_a).sort
          end.to_set
        end
      end

      # Rails.cache.fetch, computed by one process at a time. Every deletion
      # writes a jail-log row and so moves the fingerprint, and every request
      # that lists or offers a tag name reads these sets: without the lock
      # each worker's next request ran the 180-290 ms query at once. A
      # waiter reads what the holder wrote. The lock is the transaction's,
      # so a failed query releases it with the error it raised.
      def single_flight_fetch(key)
        # Five minutes bounds how long a set can outlive a lost epoch write
        # (jail_state_changed!); a hit is a fingerprint query, not the set.
        Rails.cache.fetch(key, expires_in: 5.minutes) do
          transaction(requires_new: true) do
            connection.execute(sanitize_sql_array(["SELECT pg_advisory_xact_lock(hashtext(?))", key.split("/").first(2).join("/")]))
            Rails.cache.read(key) || yield
          end
        end
      end

      # What the set reads that a write moves: the newest jail-log row and
      # the newest rename (#jail_deletions reads the name an account held),
      # in one query of at most 6 ms on production; the epoch, which every
      # commit that moves the set changes after it lands -- a row committed
      # after a newer one leaves the newest id where it was, and a tag edit
      # writes no log row at all; and the configuration the query is built from.
      def untagged_jailed_fingerprint
        CreatorVisibility.memoized(:jail_fingerprint, nil) { untagged_jailed_fingerprint_now }
      end

      def untagged_jailed_fingerprint_now
        categories = ModAction.categories.values_at(*JAIL_LOG_CATEGORIES)
        newest = connection.select_rows(<<~SQL.squish).first
          SELECT (SELECT max(id) FROM mod_actions WHERE category IN (#{categories.map(&:to_i).join(",")})),
                 (SELECT max(id) FROM user_name_change_requests)
        SQL
        parts = [*newest, Rails.cache.read(UNTAGGED_JAILED_EPOCH_KEY), jail_account_names, JAIL_DELETION_REASON, Danbooru.config.troll_jail_tag]
        Digest::SHA256.hexdigest(parts.to_json).first(24)
      end

      # The set itself, read now: deleted posts without the tag whose latest
      # deletion is a jail account's with no undeletion since
      # (#deletion_is_the_jails?), or whose latest jail-log row is a
      # post_jail (#jailing_stands?). JIT off for this query alone: it took
      # 630 ms with it and 180-290 ms without on production.
      def untagged_jailed_ids_now
        delete, undelete, jail, unjail = ModAction.categories.values_at(*JAIL_LOG_CATEGORIES).map(&:to_i)
        sql = <<~SQL.squish
          WITH candidates AS (
            SELECT posts.id FROM posts
             WHERE posts.is_deleted = TRUE
               AND NOT (string_to_array(posts.tag_string, ' ') @> ARRAY[#{connection.quote(Danbooru.config.troll_jail_tag)}]::text[])
          ), latest_delete AS (
            SELECT DISTINCT ON (m.subject_id) m.subject_id, m.id FROM mod_actions m JOIN candidates c ON c.id = m.subject_id
             WHERE m.subject_type = 'Post' AND m.category = #{delete} ORDER BY m.subject_id, m.id DESC
          ), latest_jail_event AS (
            SELECT DISTINCT ON (m.subject_id) m.subject_id, m.category FROM mod_actions m JOIN candidates c ON c.id = m.subject_id
             WHERE m.subject_type = 'Post' AND m.category IN (#{jail}, #{unjail}, #{undelete}) ORDER BY m.subject_id, m.id DESC
          )
          SELECT ld.subject_id FROM latest_delete ld
           WHERE ld.id IN (#{jail_deletions.select(:id).to_sql})
             AND NOT EXISTS (SELECT 1 FROM mod_actions u WHERE u.subject_type = 'Post' AND u.subject_id = ld.subject_id AND u.category = #{undelete} AND u.id > ld.id)
          UNION
          SELECT subject_id FROM latest_jail_event WHERE category = #{jail}
        SQL
        ids = transaction(requires_new: true) do
          connection.execute("SET LOCAL jit = off")
          connection.select_values(sql)
        end
        ids.map(&:to_i).sort
      end

      # After a commit that may move the set: a jail-log row or a rename
      # (ModAction, UserNameChangeRequest), or a post gaining or losing the
      # tag or its deletion (#announce_jail_state_change). Every process
      # reads a new fingerprint on its next request; this one forgets its own
      # memo now.
      def jail_state_changed!
        # A lost write leaves every other process on the old fingerprint and
        # serving the old sets until they expire, five minutes at most: said
        # where it shows, with what to do, not swallowed.
        unless Rails.cache.write(UNTAGGED_JAILED_EPOCH_KEY, SecureRandom.hex(8))
          DanbooruLogger.info("jail epoch write failed: the jailed-post and hidden-name sets may be up to five minutes stale on other workers. Check the Redis cache (DANBOORU_REDIS_URL) is reachable")
        end
        %i[jail_fingerprint untagged_jailed jailed name_hiding_ids name_hiding_literal tag_names].each { |kind| CreatorVisibility.forget(kind) }
      end
    end

    # A save that took troll_jail or a banished tag on or off, or the
    # deletion, may move Post.untagged_jailed_ids and
    # Post.withheld_by_jail_ids; they are told once the save commits, so no
    # other process reads the old set under the new fingerprint.
    def note_jail_state_change
      tag_moved = saved_change_to_tag_string? && begin
        tags = TagBanishment.post_tags
        tag_string_before_last_save.to_s.split.intersect?(tags) != tag_string.to_s.split.intersect?(tags)
      end
      @jail_state_changed ||= tag_moved || saved_change_to_is_deleted?
    end

    def announce_jail_state_change
      return unless @jail_state_changed

      @jail_state_changed = false
      Post.jail_state_changed!
    end

    def forget_jail_state_change
      @jail_state_changed = false
    end

    # Whether this post's CURRENT deletion is the jail's: it is deleted, the
    # latest logged deletion is a jail account's (above), and no undeletion
    # has been logged since. Both undelete doors log post_undelete
    # (PostApproval#approve_post, FourierJailController#release!), so "no
    # human undelete since" is read from the same log. The only unlogged
    # deletion is the system user's pruning of a pending post, which never
    # follows an undelete without one being logged in between.
    def deletion_is_the_jails?
      return false unless is_deleted?

      latest = ModAction.where(subject: self, category: :post_delete).order(:id).last
      return false if latest.nil? || !Post.jail_deletions.exists?(id: latest.id)

      !ModAction.where(subject: self, category: :post_undelete).exists?(["id > ?", latest.id])
    end

    # Whether a jailing the booru reported (a post_jail row) still stands:
    # nothing has ended it since -- an undeletion (post_undelete, the release
    # route's or an approval's) or the release route lifting it off another
    # account's deletion (post_unjail). Read from the booru's own log, never
    # the tag: a jailing that stood on the tag alone was undone by editing the
    # tag off and approving (review of the 2026-10-10 build). Only the jail
    # changes the tag now (R2), but a jailing must not rest on that alone.
    def jailing_stands?
      latest = ModAction.where(subject: self, category: [:post_jail, :post_unjail, :post_undelete]).order(:id).last
      latest.present? && latest.category == "post_jail"
    end

    # Deleted, and the post carries the jail tag, or its deletion is the
    # jail's, or a jailing the booru reported stands. The untagged halves are
    # the four production posts the pill's old jail-off left deleted with the
    # tag gone (2026-09-20), and a reported jailing whose tag was edited off:
    # still jailed, and still the panel's to release.
    def jailed?
      is_deleted? && (has_tag?(Danbooru.config.troll_jail_tag) || deletion_is_the_jails? || jailing_stands?)
    end

    # The refusal every ordinary undelete door gives a jailed post, with the
    # way to the panel when the panel has no row for it.
    def jail_release_refusal
      reported = deletion_is_the_jails? || jailing_stands?
      reported ? JAILED_RELEASE_DOOR : "#{JAILED_RELEASE_DOOR}; #{UNREPORTED_JAILING}"
    end

    # Ever deleted as a legal hold by a jail account. Forever: nothing
    # releases a hold, whatever happened to the post after.
    def legal_hold?
      Post.jail_deletions(LEGAL_HOLD_REASON).exists?(subject_id: id)
    end

    # A jailing the booru makes itself -- the banished-tag failsafe, the
    # pill's jail-on -- finished the same way, so the release route accepts
    # both and the jail panel hears of both (operator rulings 2026-10-09).
    # The deletion is the system user's, made on the actor's behalf (the
    # reason names a moderator), because the release route proves a jailing
    # by who deleted. delete! logs nothing for the system user (upstream's
    # routine pruning); a jailing is not routine, so it is logged here. The
    # post_jail row is the booru's report to the panel
    # (FourierJailController#index), written even when the post was already
    # deleted by someone else and only the tag was added -- that deletion
    # stays its owner's, and release then lifts only the jail.
    #
    # Callers jail first and add the tag after, so the tag lands on a post
    # already reported and #report_jailing_entered has nothing to add; and a
    # jailing already standing is not reported twice.
    def jail_by_booru!(reason)
      CurrentUser.set(user: User.system, safe_mode: false) do
        unless is_deleted?
          delete!(reason, user: User.system)
          ModAction.log("deleted post ##{id}, reason: #{reason}", :post_delete, subject: self, user: User.system)
        end
        ModAction.log("jailed post ##{id}, reason: #{reason}", :post_jail, subject: self, user: User.system) unless jailing_stands?
      end
    end

    # The booru's own jail acts add the tag here, and nowhere else: the one
    # save #validate_jail_tag_change lets through for an account that is not
    # the jail panel's (R2). Raises if the tag did not land: an alias,
    # rename or deprecation of troll_jail normalises it away, and a jailing
    # whose tag silently vanished is a deletion the panel never sees as the
    # jail's.
    def add_jail_tag!
      jail = Danbooru.config.troll_jail_tag
      return if has_tag?(jail)

      begin
        @jail_tag_by_the_jail = true
        add_tag(jail)
        save!
      ensure
        @jail_tag_by_the_jail = false
      end
      return if has_tag?(jail)

      raise ActiveRecord::RecordNotSaved.new("post ##{id}: #{jail} did not land, the tag string normalised it away. An alias, implication, rename or deprecation of #{jail} does that: remove it, then jail the post again", self)
    end

    private

    # EVERY WAY IN IS REPORTED (review of the 2026-10-10 build). A post
    # becomes jailed -- deleted, carrying troll_jail (operator ruling
    # 2026-10-10) -- not only through the pill and the banished-tag failsafe:
    # the jail panel's account can add the tag to a deleted post, and any
    # deletion of a post that carries the tag (DELETE /posts/:id, the pill's
    # delete-on, the pending-post pruner) makes one. Each is a booru-side jailing, which
    # reaches the panel (operator 2026-10-09), and each is then refused by
    # every ordinary undelete door; unreported, nothing could ever release
    # it. So a save that ENTERS that state writes the post_jail row, as the
    # system user, naming who did it -- unless the jail itself did (its
    # deletion: sampling already holds the image) or a reported jailing
    # already stands (#jail_by_booru!'s own).
    #
    # Noted before the save and acted on after it, OR-ed in, for the reason
    # note_banished_tags_gained gives: nested saves replace saved_changes.
    def note_jailing_entered
      jail = Danbooru.config.troll_jail_tag
      return unless is_deleted? && has_tag?(jail)
      return if !new_record? && is_deleted_in_database && tag_array_was.include?(jail)

      @jailing_entered = (!new_record? && is_deleted_in_database) ? :tagged : :deleted if @jailing_entered.nil?
    end

    def report_jailing_entered
      entered = @jailing_entered
      @jailing_entered = nil
      return if entered.nil? || !is_deleted? || !has_tag?(Danbooru.config.troll_jail_tag)

      # The deletion's flag, not the mod log: Post#delete! writes its flag
      # before this save and its post_delete row after it. Its flag is the
      # newest succeeded one (delete! resolves the pending ones first, and a
      # deleted post takes no new flag).
      deletion = flags.succeeded.order(:id).last
      return if jailing_stands? || jail_deletion_flag?(deletion)

      if entered == :tagged
        reason = "#{JAIL_DELETION_REASON}#{CurrentUser.user&.name || "an unknown account"} tagged a deleted post #{Danbooru.config.troll_jail_tag}"
      else
        reason = "#{JAIL_DELETION_REASON}#{(deletion&.creator || CurrentUser.user)&.name || "an unknown account"} deleted a post tagged #{Danbooru.config.troll_jail_tag}"
      end
      ModAction.log("jailed post ##{id}, reason: #{reason}", :post_jail, subject: self, user: User.system)
    end

    # A deletion flag a jail account wrote with the jail's words.
    def jail_deletion_flag?(flag)
      flag.present? && flag.reason.to_s.start_with?(JAIL_DELETION_REASON) && Post.jail_account_names.include?(flag.creator.name.to_s.downcase)
    end
  end

  # Fork: gate 1 itself (#hidden_as_gated?), under upstream's name for its
  # callers -- the image (can_see_media?, through visible?), PostPreview
  # and PostSets. One rule for the post and the image (operator,
  # 2026-10-13), so a post this blocks is already a 404 at every door, and
  # upstream's "needs a Gold account" notice is never reached for it.
  def levelblocked?(user = CurrentUser.user)
    hidden_as_gated?(user)
  end

  def banblocked?(user = CurrentUser.user)
    return true if is_taken_down? && !user.is_moderator?
    return true if is_banned? && has_tag?("paid_reward") && !user.is_approver?
    return true if is_banned? && !user.is_approver?
    false
  end

  def visible?(user = CurrentUser.user)
    !safeblocked? && !levelblocked?(user) && !banblocked?(user)
  end

  def reload(options = nil)
    super
    @pools = nil
    @tag_categories = nil
    @typed_tags = nil
    @children_shown_to = nil
    self
  end

  def self.normalize_source(source)
    if source&.match?(%r{\Ahttps?://}i)
      source.to_s
    else
      source.to_s.strip.unicode_normalize(:nfc)
    end
  end

  def mark_as_translated(params)
    add_tag("check_translation") if params["check_translation"].to_s.truthy?
    remove_tag("check_translation") if params["check_translation"].to_s.falsy?

    add_tag("partially_translated") if params["partially_translated"].to_s.truthy?
    remove_tag("partially_translated") if params["partially_translated"].to_s.falsy?

    if has_tag?("check_translation") || has_tag?("partially_translated")
      add_tag("translation_request")
      remove_tag("translated")
    else
      add_tag("translated")
      remove_tag("translation_request")
    end

    save
  end

  def self.model_restriction
    where(is_pending: false, is_flagged: false, is_deleted: false)
  end

  def self.available_includes
    # attributes accessible through the ?only= parameter
    %i[
      uploader approver flags appeals events parent children notes
      comments approvals disapprovals replacements
      artist_commentary media_asset media_metadata ai_tags dtext_links
      embedding_wiki_pages
    ]
  end
end
