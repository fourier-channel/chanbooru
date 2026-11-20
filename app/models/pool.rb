# frozen_string_literal: true

class Pool < ApplicationRecord
  # Fork: rows name posts: post_ids, and the gallery draws its cover post. Listing them is
  # members only (MembersOnly, ApplicationRecord.names_posts?).
  def self.names_posts? = true

  class RevertError < StandardError; end

  RESERVED_NAMES = %w[none any series collection]
  POOL_ORDER_LIMIT = 1000
  MAX_DESCRIPTION_LENGTH = 20_000
  MAX_POST_COUNT = 25_000

  array_attribute :post_ids, parse: /\d+/, cast: :to_i
  include PostIdList # its post ids as each viewer may see them (2026-10-08)

  dtext_attribute :description # defines :dtext_description

  normalizes :name, with: ->(name) { name.unicode_normalize(:nfc).normalize_whitespace.gsub(/[[:space:]]+/, "_").squeeze("_").gsub(/\A_|_\z/, "") }
  normalizes :post_ids, with: ->(post_ids) { post_ids.uniq }

  validates :name, visible_string: true, uniqueness: { case_sensitive: false }, length: { minimum: 3, maximum: 170 }, if: :name_changed?
  validate :validate_name, if: :name_changed?
  validates :description, length: { maximum: MAX_DESCRIPTION_LENGTH }, if: :description_changed?
  validates :post_ids, length: { maximum: MAX_POST_COUNT, too_long: "can't have more than #{MAX_POST_COUNT} posts" }, if: :post_ids_changed?
  validates :category, inclusion: { in: %w[series collection] }
  validate :updater_can_edit_deleted
  validate :added_posts_exist_for_writer, if: -> { post_ids_changed? || relisted_unseen_post_ids.present? }
  after_save :create_version

  has_many :mod_actions, as: :subject, dependent: :destroy
  has_many :reactions, as: :model, dependent: :destroy

  deletable
  has_dtext_links :description

  scope :series, -> { where(category: "series") }
  scope :collection, -> { where(category: "collection") }

  module SearchMethods
    def name_contains(name)
      name = normalize_name_for_search(name)
      name = "*#{name.escape_wildcards}*" unless name.include?("*")
      where_ilike(:name, name)
    end

    def post_tags_match(query)
      posts = Post.user_tag_match(query).select(:id).reorder(nil)
      pools = Pool.joins("CROSS JOIN unnest(post_ids) AS post_id").group(:id).where("post_id IN (?)", posts)
      where(id: pools)
    end

    def default_order
      order(updated_at: :desc)
    end

    def search(params, current_user)
      params = Post.searchable_post_id_params(params, current_user)
      q = search_attributes(params, [:id, :created_at, :updated_at, :is_deleted, :name, :description, :post_ids, :dtext_links], current_user: current_user)

      if params[:post_tags_match]
        q = q.post_tags_match(params[:post_tags_match])
      end

      if params[:name_contains].present?
        q = q.name_contains(params[:name_contains])
      end

      if params[:linked_to].present?
        q = q.linked_to(params[:linked_to])
      end

      if params[:not_linked_to].present?
        q = q.not_linked_to(params[:not_linked_to])
      end

      case params[:category]
      when "series"
        q = q.series
      when "collection"
        q = q.collection
      end

      case params[:order]
      when "name"
        q = q.order("pools.name")
      when "created_at"
        q = q.order("pools.created_at desc")
      when "post_count"
        q = q.order(Arel.sql("#{Post.visible_count_sql("pools.post_ids", current_user)} desc")).default_order
      else
        q = q.apply_default_order(params)
      end

      q
    end
  end

  extend SearchMethods

  def self.normalize_name_for_search(name)
    normalize_value_for(:name, name).downcase
  end

  def self.named(name)
    if name =~ /^\d+$/
      where(id: name.to_i)
    elsif name
      where_ilike(:name, normalize_name_for_search(name))
    else
      nil
    end
  end

  def self.find_by_name(name)
    named(name).try(:first)
  end

  def versions
    raise NotImplementedError, "Archive service not configured" unless PoolVersion.enabled?
    PoolVersion.where(pool_id: id).order(:id)
  end

  def is_series?
    category == "series"
  end

  def is_collection?
    category == "collection"
  end

  def pretty_name
    name.tr("_", " ")
  end

  def pretty_category
    category.titleize
  end

  def revert_to!(version)
    if id != version.pool_id
      raise RevertError, "You cannot revert to a previous version of another pool."
    end

    # A version can name a post since hidden from the reverter (boo.122 D5).
    # Refusing the revert named that id back to someone the version's page
    # does not show it to, and left the version unrevertable for good; the
    # revert restores the rest and says how many it left out, never which.
    keep = post_ids.to_set | Post.visible_ids_among(version.post_ids, CurrentUser.user || User.anonymous)
    keep |= Post.where(id: version.post_ids - keep.to_a).select { |post| post.writable_by?(CurrentUser.user) }.map(&:id)
    restored = version.post_ids.select { |id| keep.include?(id) }
    left_out = version.post_ids.size - restored.size
    warnings.add(:base, "#{left_out} #{"post".pluralize(left_out)} in that version no longer #{(left_out == 1) ? "exists" : "exist"} for you and #{(left_out == 1) ? "was" : "were"} left out") if left_out > 0

    self.post_ids = restored
    # And a current member hidden from the reverter stays where it is, as an
    # edit keeps it (PostIdList#keep_unseen_post_ids): taking it out is a
    # write on a post that does not exist for them (R1, operator 2026-11-20).
    keep_unseen_post_ids(CurrentUser.user || User.anonymous)
    # Those it keeps are the pool's own members, named by the revert, not by
    # the reverter.
    self.relisted_unseen_post_ids = nil
    self.name = version.name
    self.description = version.description
    save!
  end

  def contains?(post_id)
    post_ids.include?(post_id)
  end

  def page_number(post_id)
    visible_post_ids.find_index(post_id).to_i + 1
  end

  # Fork (boo.122 D5, 2026-11-20): an id added to a pool must be a post
  # that exists for whoever adds it (Post.visible_ids_among), as
  # FavoriteGroup#validate_posts holds a favorite group to its creator. A
  # pool edit, a revert and a pool:N metatag seated any id at all -- a
  # missing post, or a jailed or deleted one the writer is told does not
  # exist -- and the pool's versions and post_ids_include searches then
  # answered for it. One message for missing and hidden ids, so the refusal
  # does not tell them apart. Ids already in the pool are not judged again:
  # a post hidden after it was added stays, as it does in a favorite group.
  # Unless the writer names it again (PostIdList#keep_unseen_post_ids): then
  # it is judged as if added, so a hidden member and a hidden non-member get
  # one answer.
  def added_posts_exist_for_writer
    added = (post_ids - post_ids_was.to_a) | relisted_unseen_post_ids.to_a
    return if added.empty?

    writer = CurrentUser.user || User.anonymous
    bad = added - Post.visible_ids_among(Post.where(id: added).pluck(:id), writer)
    # A post the writer may write though it is hidden from them -- the
    # pipeline approver and a deleted post (Post#writable_by?) -- may be
    # added. A BUR "convert tag -> pool:N" runs as the system user and would
    # otherwise lose every deleted post's tag without a word.
    bad -= Post.where(id: bad).select { |post| post.writable_by?(writer) }.map(&:id)
    return if bad.empty?

    errors.add(:base, "Cannot add invalid post(s) to pool: #{bad.to_sentence}. Remove them from the list: a post that does not exist for you cannot be added")
  end

  def updater_can_edit_deleted
    if is_deleted? && !Pundit.policy!(CurrentUser.user, self).update?
      errors.add(:base, "You cannot update pools that are deleted")
    end
  end

  def create_mod_action_for_delete
    ModAction.log("deleted pool ##{id} (name: #{name})", :pool_delete, subject: self, user: CurrentUser.user)
  end

  def create_mod_action_for_undelete
    ModAction.log("undeleted pool ##{id} (name: #{name})", :pool_undelete, subject: self, user: CurrentUser.user)
  end

  def add!(post)
    return if contains?(post.id)
    return if is_deleted?

    with_lock do
      update(post_ids: post_ids + [post.id])
    end
  end

  def remove!(post)
    return unless contains?(post.id)

    with_lock do
      reload
      update(post_ids: post_ids - [post.id])
    end
  end

  # XXX unify with PostQueryBuilder ordpool search
  def posts
    pool_posts = Pool.where(id: id).joins("CROSS JOIN unnest(pools.post_ids) WITH ORDINALITY AS row(post_id, pool_index)").select(:post_id, :pool_index)
    posts = Post.joins("JOIN (#{pool_posts.to_sql}) pool_posts ON pool_posts.post_id = posts.id").order("pool_posts.pool_index ASC")
    # Fork: only the posts that exist for the viewer (PostIdList).
    (visible_post_ids.size == post_ids.size) ? posts : posts.where(id: visible_post_ids)
  end

  def post_count
    visible_post_ids.size
  end

  def cover_post
    (post_count > 0) ? Post.find(visible_post_ids.first) : nil
  end

  def create_version(updater: CurrentUser.user)
    if PoolVersion.enabled?
      PoolVersion.queue(self, updater)
    else
      Rails.logger.warn("Archive service is not configured. Pool versions will not be saved.")
    end
  end

  def last_page
    (post_count / CurrentUser.user.per_page.to_f).ceil
  end

  def validate_name
    case name.downcase
    when *RESERVED_NAMES
      errors.add(:name, "cannot be any of the following names: #{RESERVED_NAMES.to_sentence(last_word_connector: ", or ")}")
    when /,/
      errors.add(:name, "cannot contain commas")
    when /\*/
      errors.add(:name, "cannot contain asterisks")
    when /\A_/
      errors.add(:name, "cannot begin with an underscore")
    when /_\z/
      errors.add(:name, "cannot end with an underscore")
    when /__/
      errors.add(:name, "cannot contain consecutive underscores")
    when /[^[:graph:]]/
      errors.add(:name, "cannot contain non-printable characters")
    when ""
      errors.add(:name, "cannot be blank")
    when /\A[0-9]+\z/
      errors.add(:name, "cannot contain only digits")
    end
  end

  def self.rewrite_wiki_links!(old_name, new_name)
    Pool.linked_to(old_name).each do |pool|
      pool.with_lock do
        pool.description = DText.new(pool.description).rewrite_wiki_links(old_name, new_name).to_s
        pool.save!(validate: false)
      end
    end
  end
end
