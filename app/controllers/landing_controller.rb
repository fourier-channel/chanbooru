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

  def show
    skip_authorization

    # `?show=1` is the way back in for someone who chose the gallery: without it
    # they could never see the landing page again on this browser, which is a
    # preference that has become a trapdoor.
    if cookies[PREFERENCE_COOKIE].to_s == GALLERY && params[:show].blank?
      redirect_to(posts_path) and return
    end

    @categories = showcase.categories
    @promoted = CreatorGallery.landing_promoted.to_a
    @preference = cookies[PREFERENCE_COOKIE].to_s
  end

  # A fresh set, for the page to swap in on its timer without a reload.
  #
  # Carries the hidden pool markup as well as the slides, because the blacklist
  # matches on ELEMENTS. A slide that arrives without its pool item is a slide
  # the viewer's blacklist never sees, which is the quietest way to show someone
  # the thing they asked never to see. Rendered from the same partial the page
  # uses, so the two cannot drift apart.
  def slides
    skip_authorization
    categories = showcase.categories
    pool = categories.flat_map { |c| c[:slides].map { |s| s.merge(category: c[:key]) } }
    render json: {
      categories: categories,
      pool: render_to_string(partial: "landing/pool_item", collection: pool, as: :slide, formats: [:html]),
    }, status: 200
  end

  # POST rather than a link: it writes state, and a preference that a link
  # prefetcher can set on someone's behalf is not a preference.
  def preference
    skip_authorization
    choice = (params[:landing].to_s == GALLERY) ? GALLERY : LANDING
    cookies.permanent[PREFERENCE_COOKIE] = { value: choice, same_site: :lax }

    redirect_to((choice == GALLERY) ? posts_path : root_path(show: 1))
  end

  private

  def showcase
    @showcase ||= LandingShowcase.new(viewer: CurrentUser.user)
  end
end
