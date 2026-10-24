# frozen_string_literal: true

# Fork: a claimed original character's wiki page is its creator's (OC
# ownership, operator ruling 2026-10-11, Q3: exclusive -- the owner and admins
# only). Read from stored rows (CharacterClaim), never from the request: the
# owner edits as their linked booru account with no Matrix header. Both the
# page's title and the title it had are asked, so neither a page renamed onto
# a claimed title nor a claimed page renamed away gets past anyone but an
# admin. An unclaimed page answers exactly as upstream.
class WikiPagePolicy < ApplicationPolicy
  def show_or_new?
    true
  end

  # Two callers ask with the CLASS (the "New" link, show_or_new), which has no
  # title to look up.
  def create?
    return super unless record.is_a?(WikiPage)

    update?
  end

  def update?
    return false unless unbanned?
    return claimed_page_writable? if character_claims.any?

    # The lock the page HAS: a revert applies the version (lock included)
    # before it is authorized, and upstream asked the page as it stood.
    can_edit_locked? || !record.is_locked_was
  end

  # The keeper is told the rule that stopped them -- only an admin moves a
  # claimed page's title -- and everyone else whose page it is and where to
  # write to them.
  def denial_message(_query)
    claim = record.is_a?(WikiPage) && character_claims.first
    return nil unless claim

    if record.persisted? && record.title_changed? && character_claims.any? { |c| c.user_id == user.id }
      "Only an admin moves a page onto or off a claimed character's title (#{claim.tag_name}): keep the title " \
        "#{record.title_was}, or ask an admin to move it."
    else
      remedy = claim.contact_for?(user) ? "message them from their creator page, #{Routes.creator_gallery_path(claim.slug)}" : "ask an admin"
      "#{claim.tag_name}'s wiki belongs to its creator, @#{claim.slug}. Only they or an admin can edit it. To suggest a change, #{remedy}."
    end
  end

  def revert?
    update?
  end

  def can_edit_locked?
    user.is_builder?
  end

  def can_see_updater_notice?
    user.is_moderator?
  end

  def new_editor?
    !user.wiki_page_versions.exists?(created_at: ..24.hours.ago)
  end

  def is_large_tag?
    Tag.where(name: record.title).exists?(name: Tag.order(post_count: :desc).limit(500).select(:name))
  end

  def rate_limit_for_write(**_options)
    if record.invalid?
      { action: "wiki_pages:write:invalid", rate: 1.0 / 1.second, burst: 1 }
    elsif user.wiki_page_versions.exists?(wiki_page: record, created_at: 1.hour.ago..)
      { action: "wiki_pages:write:wiki-page-#{record.id}", rate: 4.0 / 1.minute, burst: 10 } # 240 per hour, 250 in first hour
    elsif user.is_builder?
      { action: "wiki_pages:write", rate: 8.0 / 1.minute, burst: 120 } # 480 per hour, 600 in first hour
    elsif !new_editor?
      { action: "wiki_pages:write", rate: 2.0 / 1.minute, burst: 30 } # 120 per hour, 150 in first hour
    elsif is_large_tag? && new_editor?
      { action: "wiki_pages:write:large", rate: 1.0 / 1.5.minutes, burst: 1 } # 40 per hour, 40 in first hour
    else
      { action: "wiki_pages:write", rate: 1.0 / 1.5.minutes, burst: 10 } # 40 per hour, 50 in first hour
    end
  end

  def permitted_attributes
    [:title, :body, :other_names, :other_names_string, :is_deleted, (:is_locked if can_edit_locked?)].compact
  end

  private

  # The standing claims on this page's title or the title it had: one query,
  # once per policy, none for a title no claim could have.
  def character_claims
    @character_claims ||= CharacterClaim.standing_on([record.title, record.title_was].compact.uniq)
  end

  # An admin, or the keeper of this very title while it keeps it: a builder's
  # locked-page override does not apply, and a lock does not stop the owner.
  def claimed_page_writable?
    return true if user.is_admin?
    return false if record.persisted? && record.title_changed?

    # unbanned? already held: signed in, not banned, not restricted.
    character_claims.any? { |claim| claim.user_id == user.id && claim.tag_name == record.title }
  end
end
