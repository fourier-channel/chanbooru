# frozen_string_literal: true

class PostNavbarComponent < ApplicationComponent
  extend Memoist

  attr_reader :post, :current_user, :search

  def initialize(post:, current_user:, search: nil)
    super
    @post = post
    @current_user = current_user
    @search = search.presence || "status:any"
  end

  def render?
    has_search_navbar? || pools.any? || favgroups.any?
  end

  def pools
    # Fork: each pool's neighbours are its posts that exist for the viewer
    # (PostIdList), decided once for every pool in the bar.
    @pools ||= Pool.preload_visible_post_ids(post.pools.undeleted, current_user).sort_by do |pool|
      [(pool == selected_pool) ? 0 : 1, pool.is_series? ? 0 : 1, pool.name]
    end
  end

  def favgroups
    return [] if current_user.is_anonymous? && selected_favgroup.nil?

    favgroups = FavoriteGroup.visible(current_user).for_post(post.id)
    favgroups = favgroups.where(creator: current_user).or(favgroups.where(id: selected_favgroup))
    FavoriteGroup.preload_visible_post_ids(favgroups, current_user).sort_by do |favgroup|
      [(favgroup == selected_favgroup) ? 0 : 1, favgroup.name]
    end
  end

  def has_search_navbar?
    !query.has_metatag?(:order, :ordfav, :ordvote, :ordpool) && selected_pool.blank? && selected_favgroup.blank?
  end

  def selected_pool
    return nil unless query.is_metatag?(:pool) || query.is_metatag?(:ordpool)
    value = query.find_metatag(:pool, :ordpool)
    Pool.find_by_name(value) if value.present?
  end

  def selected_favgroup
    return nil unless query.is_metatag?(:favgroup) || query.is_metatag?(:ordfavgroup)
    value = query.find_metatag(:favgroup, :ordfavgroup)
    FavoriteGroup.find_by_name_or_id(value, current_user) if value.present?
  end

  def query
    @query ||= PostQuery.new(search).trim
  end

  memoize :favgroups, :selected_pool, :selected_favgroup
end
