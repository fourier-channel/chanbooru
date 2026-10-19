# frozen_string_literal: true

# This component represents the tooltip that displays when you hover over a post's favorite count.
class FavoritesTooltipComponent < ApplicationComponent
  attr_reader :post, :current_user

  def initialize(post:, current_user:)
    super
    @post = post
    @current_user = current_user
  end

  # Fork: a list of users, so at most the viewer's page
  # (User#listing_per_page_limit; ACCOUNT_LIMITS.md: every list is bounded).
  def favorites
    post.favorites.includes(:user).order(id: :desc).limit(current_user.listing_per_page_limit)
  end

  def favoriter_name(favorite)
    if policy(favorite).can_see_favoriter?
      link_to_user(favorite.user)
    else
      tag.i("hidden")
    end
  end
end
