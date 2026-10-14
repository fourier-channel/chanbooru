# frozen_string_literal: true

# THE ERROR PAGE'S PICTURE (operator, 2026-10-11): booru posts chosen on the
# landing console (LandingSetting#error_page_post_ids), one drawn at random on
# each load of the "Oh No!" page (static/_oh_no.html.erb), and the status line
# the console shows for each.
#
# THE HERO BAND'S MECHANIC, REUSED, NOT COPIED. There is no grant to give a
# post: a signed-out visitor is shown exactly what LandingShowcase.showable?
# passes for them, and nothing here widens that.
#
# - The rule is LandingShowcase.showable?, the one the hero band asks for
#   every slide, asked as the signed-out visitor (User.anonymous) AND as the
#   viewer in front of the page (a creator's block can hide a public post from
#   one signed-in account). Plus "is an image": the square is an <img>.
# - The picture loads through the same door a slide's does, large_file_url,
#   which fourier-auth's media gate releases after asking the booru
#   anonymously whether the post may be seen -- so it loads for a signed-out
#   visitor because the post passes the same rule, not because of an exception.
# - A signed-out viewer's draw is recorded exactly as a slide's is
#   (MembersOnly.remember_shown_to_anonymous), so the picture links to its
#   post page and that page opens for them.
#
# A post a signed-out visitor may not see is NEVER drawn, to anyone, and the
# console draws no thumbnail of it either (operator: no carve-outs that make
# hidden posts visible; jailed means deleted).
#
# LEAN. Which listed posts pass the anonymous rule is cached for CACHE_TTL,
# keyed on the setting's version, so a console save takes effect at once. A
# load then fetches at most TRIES random candidates in one query and re-asks
# the rule of each -- authoritative, so a post jailed a second ago is never
# drawn from a stale cache -- and draws the first that passes, else nothing.
#
# NEVER RAISES. The error page also renders for 500s, possibly with the
# database down: any failure is logged and the placeholder drawn.
module ErrorPagePicture
  module_function

  CACHE_TTL = 60.seconds
  TRIES = 3

  Picture = Data.define(:post_id, :src, :url, :alt)

  # A listed id as the console reports it. A skipped post carries no Post and
  # no address, so the console has nothing of it to draw by mistake.
  Status = Data.define(:id, :shown, :reason, :thumb, :url)

  # @return [Picture, nil] the picture to draw, or nil for the placeholder
  def pick(viewer:, request:)
    viewer ||= User.anonymous
    setting = LandingSetting.current
    return nil if setting.error_page_post_ids.empty?

    candidates = anonymous_ids(setting).sample(TRIES)
    by_id = candidates.empty? ? {} : Post.where(id: candidates).includes(:media_asset).index_by(&:id)
    post = candidates.filter_map { |id| by_id[id] }.find { |candidate| drawable?(candidate, viewer) }
    return nil if post.nil?

    picture = Picture.new(post_id: post.id, src: post.large_file_url, url: routes.post_path(post), alt: alt_for(post, viewer))
    if MembersOnly.default_deny? && MembersOnly.signed_out?(viewer, request)
      MembersOnly.remember_shown_to_anonymous([post.id], safe_mode: CurrentUser.safe_mode?)
    end
    picture
  rescue StandardError => e
    DanbooruLogger.log(e, context: "error_page_picture")
    nil
  end

  # The console's line for every listed id, in the listed order.
  #
  # @return [Array<Status>]
  def statuses(setting, viewer:)
    ids = setting.error_page_post_ids
    by_id = Post.where(id: ids).includes(:media_asset).index_by(&:id)
    ids.map do |id|
      post = by_id[id]
      if post.nil?
        Status.new(id: id, shown: false, reason: "missing -- no post has this number", thumb: nil, url: nil)
      elsif !shown_to_anonymous?(post)
        Status.new(id: id, shown: false, reason: skip_reason(post), thumb: nil, url: nil)
      elsif LandingShowcase.showable?(post, viewer)
        Status.new(id: id, shown: true, reason: nil, thumb: post.preview_file_url, url: routes.post_path(post))
      else
        # Shown to signed-out visitors but withheld from this account (a
        # creator's block): no thumbnail.
        Status.new(id: id, shown: true, reason: "not shown to your own account, so no thumbnail here", thumb: nil, url: nil)
      end
    end
  end

  # The listed posts a signed-out visitor may be shown, briefly cached.
  def anonymous_ids(setting)
    key = ["error_page_picture", "anonymous_ids", setting.cache_key_with_version, CurrentUser.safe_mode? ? "safe" : "all"]
    Rails.cache.fetch(key, expires_in: CACHE_TTL) do
      Post.where(id: setting.error_page_post_ids).select { |post| shown_to_anonymous?(post) }.map(&:id)
    end
  end

  def shown_to_anonymous?(post)
    post.is_image? && LandingShowcase.showable?(post, User.anonymous)
  end

  def drawable?(post, viewer)
    shown_to_anonymous?(post) && LandingShowcase.showable?(post, viewer)
  end

  # Short and honest: which post it is, and whose, when it names an artist.
  def alt_for(post, viewer)
    artist = TagBanishment.filter(post.typed_tags("artist"), viewer).first
    artist ? "Post ##{post.id} by #{artist.tr("_", " ")}" : "Post ##{post.id}"
  end

  # WHY a post the rule refused is skipped, in plain words for the console.
  # Asked only after LandingShowcase.showable? said no: it explains the
  # decision and never makes it, so it cannot let anything through.
  def skip_reason(post)
    anonymous = User.anonymous
    return "deleted or jailed" if post.is_deleted? || post.has_tag?(Danbooru.config.troll_jail_tag)
    return "carries a banished tag" if post.tag_array.intersect?(TagBanishment.list)
    return "carries a tag flagged for review" if post.hidden_as_flagged?(anonymous)
    return "not an image" unless post.is_image?
    return "hidden by its creator" if post.hidden_by_creator?(anonymous) || post.hidden_by_creator_prefix?(anonymous)
    return "gated for signed-out visitors" if post.hidden_as_gated?(anonymous)
    return "banned or taken down" if post.banblocked?(anonymous)

    "not shown to signed-out visitors"
  end

  def routes
    Rails.application.routes.url_helpers
  end
end
