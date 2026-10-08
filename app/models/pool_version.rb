# frozen_string_literal: true

class PoolVersion < ApplicationRecord
  # Fork: rows name posts: post_ids, added and removed. Listing them is
  # members only (MembersOnly, ApplicationRecord.names_posts?).
  def self.names_posts? = true

  dtext_attribute :description # defines :dtext_description

  belongs_to :updater, class_name: "User"
  belongs_to :pool

  # Fork: the ids a viewer is shown leave out the posts hidden from them, as
  # Pool#visible_post_ids does for the pool itself (2026-10-08). The stored
  # history stays whole: a revert restores it.
  attr_writer :hidden_post_ids

  # A page of versions decided in one query (HiddenPostIds), not one a row:
  # the JSON, the listing's count and its diff each ask.
  def self.preload_visible_post_ids(versions, user = CurrentUser.user)
    versions = versions.to_a
    hidden = HiddenPostIds.new(user, versions.flat_map { |version| version.post_ids + version.added_post_ids + version.removed_post_ids })
    versions.each { |version| version.hidden_post_ids = hidden }
  end

  # `ids` (this version's, or a diff against another) without the posts
  # hidden from `user`.
  def visible_ids(ids, user = CurrentUser.user)
    @hidden_post_ids = HiddenPostIds.new(user) unless @hidden_post_ids && @hidden_post_ids.user == user
    @hidden_post_ids.visible(ids)
  end

  def serializable_hash(...)
    hash = super
    %w[post_ids added_post_ids removed_post_ids].each do |key|
      hash[key] = visible_ids(hash[key]) if hash[key].is_a?(Array)
    end
    hash
  end

  def self.enabled?
    Rails.env.test? || Danbooru.config.aws_sqs_archives_url.present?
  end

  def self.database_url
    ENV["ARCHIVE_DATABASE_URL"] || ENV["DATABASE_URL"]
  end

  establish_connection database_url if enabled?

  module SearchMethods
    def default_order
      order(updated_at: :desc)
    end

    def for_user(user_id)
      where(updater_id: user_id)
    end

    def for_post_id(post_id)
      where_array_includes_any(:added_post_ids, [post_id]).or(where_array_includes_any(:removed_post_ids, [post_id]))
    end

    def name_contains(name)
      name = normalize_name_for_search(name)
      name = "*#{name.escape_wildcards}*" unless name.include?("*")
      where_ilike(:name, name)
    end

    def search(params, current_user)
      # Fork: found by the posts that exist for the searcher, as Pool.search
      # is (Post.searchable_post_id_params; second review, 2026-10-08).
      params = Post.searchable_post_id_params(params, current_user)
      q = search_attributes(params, %i[id created_at updated_at pool_id post_ids added_post_ids removed_post_ids updater_id description description_changed name name_changed version is_active is_deleted category], current_user: current_user)

      if params[:post_id]
        q = q.for_post_id(params[:post_id].to_i)
      end

      if params[:name_contains].present?
        q = q.name_contains(params[:name_contains])
      end

      if params[:updater_name].present?
        q = q.where(updater_id: User.name_to_id(params[:updater_name]))
      end

      if params[:is_new].to_s.truthy?
        q = q.where(version: 1)
      elsif params[:is_new].to_s.falsy?
        q = q.where("version != 1")
      end

      q.apply_default_order(params)
    end
  end

  extend SearchMethods

  def self.sqs_service
    SqsService.new(Danbooru.config.aws_sqs_archives_url)
  end

  def self.queue(pool, updater)
    # queue updates to sqs so that if archives goes down for whatever reason it won't
    # block pool updates
    raise NotImplementedError, "Archive service is not configured." if !enabled?

    json = {
      pool_id: pool.id,
      post_ids: pool.post_ids,
      updater_id: updater.id,
      created_at: pool.created_at.try(:iso8601),
      updated_at: pool.updated_at.try(:iso8601),
      description: pool.description,
      name: pool.name,
      is_active: pool.is_active?,
      is_deleted: pool.is_deleted?,
      category: pool.category,
    }
    msg = "add pool version\n#{json.to_json}"
    sqs_service.send_message(msg, message_group_id: "pool:#{pool.id}")
  end

  def self.normalize_name(name)
    name.gsub(/[_[:space:]]+/, "_").gsub(/\A_|_\z/, "")
  end

  def self.normalize_name_for_search(name)
    normalize_name(name).downcase
  end

  def previous
    @previous ||= PoolVersion.where("pool_id = ? and version < ?", pool_id, version).order(version: :desc).limit(1).to_a
    @previous.first
  end

  def current
    @current ||= PoolVersion.where(pool_id: pool_id).order(version: :desc).limit(1).to_a
    @current.first
  end

  def self.status_fields
    {
      posts_changed: "Posts",
      name: "Renamed",
      description: "Description",
      category: "Category",
      was_deleted: "Deleted",
      was_undeleted: "Undeleted",
      was_activated: "Activated",
      was_deactivated: "Deactivated",
    }
  end

  def posts_changed(type)
    other = send(type)
    ((post_ids - other.post_ids) | (other.post_ids - post_ids)).length.positive?
  end

  def was_deleted(type)
    other = send(type)
    if type == "previous"
      is_deleted && !other.is_deleted
    else
      !is_deleted && other.is_deleted
    end
  end

  def was_undeleted(type)
    other = send(type)
    if type == "previous"
      !is_deleted && other.is_deleted
    else
      is_deleted && !other.is_deleted
    end
  end

  def was_activated(type)
    other = send(type)
    if type == "previous"
      is_active && !other.is_active
    else
      !is_active && other.is_active
    end
  end

  def was_deactivated(type)
    other = send(type)
    if type == "previous"
      !is_active && other.is_active
    else
      is_active && !other.is_active
    end
  end

  def pretty_name
    name.tr("_", " ")
  end

  def self.available_includes
    [:updater, :pool]
  end
end
