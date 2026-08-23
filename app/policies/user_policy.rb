# frozen_string_literal: true

class UserPolicy < ApplicationPolicy
  # Signup being closed is a SERVER-side fact.
  #
  # It was previously expressed as `opacity: 0.4; pointer-events: none` on the
  # form plus a JS-inserted notice, injected globally through
  # custom_html_header_content. That greys out the door; it does not lock it. A
  # POST to /users with a valid CSRF token created a real account, and an
  # account is exactly what the media gate is checking for -- so the one
  # mechanism holding the site closed could be stepped around with curl.
  #
  # Danbooru.config.enable_signup? existed for this and was read by nothing.
  def create?
    user.is_anonymous? && Danbooru.config.enable_signup?
  end

  # Deliberately NOT gated on the config: the page still renders when signups
  # are closed, because it is where a visitor is told what is going on. Turning
  # the only explanation into a 403 answers the question with a slammed door.
  def new?
    user.is_anonymous?
  end

  def custom_style?
    record == user
  end

  def edit?
    record.id == user.id || user.is_owner?
  end

  def update?
    record.id == user.id
  end

  def deactivate?
    (record.id == user.id && !user.is_anonymous?) || user.is_owner?
  end

  def destroy?
    deactivate?
  end

  def promote?
    user.is_moderator?
  end

  def upgrade?
    !user.is_anonymous?
  end

  def fix_counts?
    !user.is_anonymous?
  end

  def can_see_last_logged_in_at?
    user.is_moderator?
  end

  def can_see_favorites?
    user.is_admin? || record.id == user.id || !record.enable_private_favorites?
  end

  def can_enable_private_favorites?
    user.is_gold?
  end

  def can_recover_account?
    user.is_admin? && record.level < user.level && record.level < User::Levels::MODERATOR
  end

  def rate_limit_for_create(**_options)
    if record.invalid?([:create, :deliverable])
      { action: "users:create:invalid", rate: 1.0 / 1.second, burst: 10 }
    else
      { action: "users:create", rate: 1.0 / 5.minutes, burst: 3 }
    end
  end

  def permitted_attributes_for_create
    [:name, :password, :password_confirmation]
  end

  def permitted_attributes_for_update
    %i[
      comment_threshold default_image_size favorite_tags
      blacklisted_tags time_zone per_page custom_style theme
      receive_email_notifications
      new_post_navigation_layout enable_private_favorites
      show_deleted_posts show_deleted_children
      disable_categorized_saved_searches disable_tagged_filenames
      disable_mobile_gestures enable_safe_mode
      enable_desktop_mode disable_post_tooltips
    ].compact
  end

  def api_attributes
    attributes = %i[
      id created_at name inviter_id level level_string
      post_upload_count post_update_count note_update_count is_banned is_deleted
    ]

    if record.id == user.id
      attributes += User::ACTIVE_BOOLEAN_ATTRIBUTES
      attributes += %i[
        updated_at last_logged_in_at last_forum_read_at
        comment_threshold default_image_size
        favorite_tags blacklisted_tags time_zone per_page
        custom_style favorite_count statement_timeout favorite_group_limit
        tag_query_limit max_saved_searches theme
      ]
    end

    attributes += [:last_ip_addr] if policy(:ip_address).show?

    attributes
  end

  alias_method :profile?, :show?
  alias_method :settings?, :edit?
  alias_method :demote?, :promote?
end
