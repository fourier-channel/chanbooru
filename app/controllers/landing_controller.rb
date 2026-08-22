# frozen_string_literal: true

# The landing page: an evergreen preview of the site for anyone who arrives at
# the bare domain, and the shop window for promoted creators.
#
# It is what "/" serves for everyone, with a remembered preference for people who
# would rather go straight to the gallery -- see #preference. Browsing lives at
# /posts and is unchanged.
class LandingController < ApplicationController
  respond_to :html, :json

  PREFERENCE_COOKIE = :landing_preference
  GALLERY = "gallery"
  LANDING = "landing"
  PROMOTED_LIMIT = 6

  def show
    skip_authorization

    # `?show=1` is the way back in for someone who chose the gallery: without it
    # they could never see the landing page again on this browser, which is a
    # preference that has become a trapdoor.
    if cookies[PREFERENCE_COOKIE].to_s == GALLERY && params[:show].blank?
      redirect_to(posts_path) and return
    end

    @slides = showcase.slides
    @feature = CreatorGallery.current_feature
    @promoted = promoted_galleries
    @preference = cookies[PREFERENCE_COOKIE].to_s
  end

  # A fresh shuffle, for the page to swap in on its timer without a reload.
  def slides
    skip_authorization
    render json: { slides: showcase.slides }, status: :ok
  end

  # POST rather than a link: it writes state, and a preference that a link
  # prefetcher can set on someone's behalf is not a preference.
  def preference
    skip_authorization
    choice = (params[:landing].to_s == GALLERY) ? GALLERY : LANDING
    cookies.permanent[PREFERENCE_COOKIE] = { value: choice, same_site: :lax }

    redirect_to(choice == GALLERY ? posts_path : root_path(show: 1))
  end

  private

  def showcase
    @showcase ||= LandingShowcase.new(viewer: CurrentUser.user)
  end

  # The current feature is shown in its own section, so it does not also appear
  # in the row underneath it.
  def promoted_galleries
    scope = CreatorGallery.promoted
    scope = scope.where.not(id: @feature.id) if @feature.present?
    scope.limit(PROMOTED_LIMIT).to_a
  end
end
