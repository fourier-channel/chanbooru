# frozen_string_literal: true

class TagsController < ApplicationController
  respond_to :html, :xml, :json

  def index
    # visible_to before the search, so the exclusion survives whatever the search
    # params ask for -- including a name_matches that names a gated tag outright.
    scope = Tag.visible_to(CurrentUser.user)

    if request.format.html?
      @tags = authorize scope.paginated_search(params, defaults: { hide_empty: true })
    else
      @tags = authorize scope.paginated_search(params)
    end

    @tags = @tags.includes(:consequent_aliases) if request.format.html?
    respond_with(@tags)
  end

  def show
    @tag = authorize Tag.find(params[:id])
    respond_with(@tag)
  end

  def edit
    @tag = authorize Tag.find(params[:id])
    respond_with(@tag)
  end

  def update
    @tag = authorize Tag.find(params[:id])
    @tag.update(updater: CurrentUser.user, **permitted_attributes(@tag))
    respond_with(@tag)
  end
end
