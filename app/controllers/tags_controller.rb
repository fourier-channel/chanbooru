# frozen_string_literal: true

class TagsController < ApplicationController
  respond_to :html, :xml, :json

  # The flagged-tag review queue's verbs (TagQuarantine), sent as
  # tag[quarantine] on the existing routes: PATCH /tags/:id and POST /tags.
  QUARANTINE_ACTIONS = %w[flag release banish].freeze

  def index
    # visible_to before the search, so the exclusion survives whatever the search
    # params ask for -- including a name_matches that names a gated tag outright.
    scope = Tag.visible_to(CurrentUser.user)

    # The review queue (GET /tags?search[quarantine]=flagged) lists flagged
    # tags whether or not anything carries them yet: a pre-flagged name has
    # no posts.
    @quarantine_queue = params.dig(:search, :quarantine) == "flagged" && policy(Tag).can_change_quarantine?
    if request.format.html?
      @tags = authorize scope.paginated_search(params, defaults: { hide_empty: !@quarantine_queue })
    else
      @tags = authorize scope.paginated_search(params)
    end

    @tags = @tags.includes(:consequent_aliases) if request.format.html?
    @quarantines = TagQuarantine.where(tag_id: @tags.map(&:id)).includes(:flagged_by).index_by(&:tag_id) if @quarantine_queue && request.format.html?
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

  # POST /tags: an admin PRE-FLAGS a name, used or not -- the only thing this
  # creates a tag for (tag[name], tag[quarantine]=flag). Closes the window in
  # which the first post carrying a new name is public until someone flags
  # it. A name already in use is flagged as it is.
  def create
    refuse_unless_admin!
    authorize Tag
    unless quarantine_param == "flag"
      return render_refusal("POST /tags only pre-flags a tag: send tag[name] with tag[quarantine]=flag")
    end

    @tag = Tag.find_or_create_by_name(params.dig(:tag, :name).to_s)
    return render_refusal("#{@tag.errors.full_messages.to_sentence}: give a valid tag name in tag[name]") if @tag.new_record?

    change_quarantine!(@tag)
    respond_with(@tag, location: quarantine_queue_location)
  rescue TagQuarantine::Refused => e
    render_refusal(e.message)
  end

  def update
    @tag = authorize Tag.find(params[:id])
    return update_quarantine if quarantine_param.present?

    @tag.update(updater: CurrentUser.user, **permitted_attributes(@tag).except(:quarantine_note))
    respond_with(@tag)
  end

  private

  # PATCH /tags/:id with tag[quarantine]: the queue's verb alone; any other
  # attribute in the same request is refused, so a flip never half-applies.
  def update_quarantine
    refuse_unless_admin!
    return render_refusal("tag[quarantine] must be one of #{QUARANTINE_ACTIONS.join(", ")}") unless QUARANTINE_ACTIONS.include?(quarantine_param)

    others = params.fetch(:tag, {}).keys - %w[quarantine quarantine_note]
    return render_refusal("send tag[quarantine] on its own (with tag[quarantine_note]); #{others.join(", ")} must go in a separate request") if others.any?

    change_quarantine!(@tag)
    respond_with(@tag, location: quarantine_queue_location)
  rescue TagQuarantine::Refused => e
    render_refusal(e.message)
  end

  def quarantine_param = params.dig(:tag, :quarantine).to_s.presence

  # Flag, release or banish, in the mod log under the caller's name. Only an
  # admin (TagPolicy#can_change_quarantine?): anyone else is refused with
  # why, before strong params would refuse the unknown key.
  def refuse_unless_admin!
    return if policy(Tag).can_change_quarantine?

    raise User::PrivilegeError, "only an admin may flag, release or banish a tag; ask an admin (the review queue is /tags?search[quarantine]=flagged)"
  end

  def change_quarantine!(tag)
    refuse_unless_admin!
    note = params.dig(:tag, :quarantine_note).to_s
    row = TagQuarantine.find_by(tag_id: tag.id)
    case quarantine_param
    when "flag"
      TagQuarantine.flag!(tag, by: CurrentUser.user, note: note)
    when "release"
      raise TagQuarantine::Refused, "#{tag.name} is not flagged: there is nothing to release" if row.nil?

      row.release!(by: CurrentUser.user, note: note)
    when "banish"
      row ||= TagQuarantine.flag!(tag, by: CurrentUser.user, note: note)
      row.banish!(by: CurrentUser.user, note: note)
    end
    flash[:notice] = "#{tag.name}: #{quarantine_param} done" if request.format.html?
  end

  def quarantine_queue_location
    tags_path(search: { quarantine: "flagged" })
  end

  def render_refusal(message)
    respond_to do |format|
      format.html { redirect_back_or_to(quarantine_queue_location, notice: message) }
      format.any { render json: { success: false, error: message }, status: 422 }
    end
  end
end
