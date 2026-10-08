# frozen_string_literal: true

# MEMBERS ONLY: the one refusal a signed-out visitor gets from a page that is
# for members, and the rule that every listing naming posts is such a page.
#
# THE REFUSAL is the 404 a hidden post gets (ActiveRecord::RecordNotFound,
# rendered by ApplicationController as "That record was not found."), the
# same answer the retired sections give: a 403 or a redirect to /login would
# confirm there is something there. It was first written inline for
# /creator_prefixes (operator, 2026-10-07); it lives here so a second
# members-only page is the same page, not a second rule.
#
# THE LISTING RULE (operator, 2026-10-07): "An anonymous viewer is not
# supposed to be paging through all of the content 20 posts at a time." The
# browsing cap (PostSets::Post#enforce_browsing_cap!) held /posts to one page,
# but nothing else asked it. Measured on production that day as a signed-out
# visitor: /explore/posts/popular answered every page, every date and any
# `limit=` (walking ?date= backwards enumerates the whole booru at page 1);
# /artist_commentaries?page=2 answered 40 posts with previews and their source
# lines; /post_approvals?page=2 22 posts with previews; /favorites,
# /post_events, /post_votes, /post_appeals, /post_flags, /post_replacements,
# /favorite_groups and /uploads all answered 200.
#
# Where it is asked, so a listing added later gets it without knowing:
#
# - ApplicationRecord.paginated_search, the one place every index door
#   passes, for every model whose rows name posts (`names_posts?`: any model
#   that belongs_to :post, plus the ones that name posts another way and say
#   so by overriding it). The same family without_hidden_posts covers.
# - The few doors that list posts without paginated_search, by hand:
#   /explore/posts/popular, /pools/gallery, a pool's and a favorite group's
#   page of posts, /comments grouped by post, /iqdb_queries,
#   /recommended_posts and /moderator/dashboard.
#
# A post's own page, /posts and the landing page are not listings in this
# sense and are untouched: /posts keeps its browsing cap, and a post's page
# answers by Post#hidden_from?. A signed-in member at ANY level sees exactly
# what they saw before.
module MembersOnly
  module_function

  # Signed in, at any level. The anonymous user is the only non-member.
  def member?(user)
    user.present? && !user.is_anonymous?
  end

  # Refuse a non-member with the hidden-post 404.
  def require!(user)
    raise ActiveRecord::RecordNotFound unless member?(user)
  end

  # Is this user shown listings that name posts? See the config switch for
  # why it is off under test.
  def sees_post_listings?(user)
    !Danbooru.config.post_listings_members_only? || member?(user)
  end

  # The listing rule: refuse a non-member a listing that names posts.
  def post_listing!(user)
    raise ActiveRecord::RecordNotFound unless sees_post_listings?(user)
  end

  # ---------------------------------------------------------------------------
  # DEFAULT-DENY FOR A SIGNED-OUT VIEWER (operator, 2026-10-07: "I'm trying to
  # solidify the view surfaces and keep finding new ways for danbooru to show
  # every single post to whoever bothered to ask.")
  #
  # The listing rule above closed the doors somebody had found. This closes
  # the ones nobody has found yet: a signed-out viewer is refused EVERY
  # controller action except the ones on ANONYMOUS_DOORS below, with the same
  # 404 as require!. A route added later is closed until someone adds it here
  # on purpose, with a reason. anonymous_default_deny_test walks the whole
  # routes table to hold that.
  #
  # WHO IS SIGNED OUT. No booru session, no API key, AND no verified Matrix
  # identity (X-Fourier-Identity, which only the reverse proxy sets, from
  # fourier-auth's session). The Matrix half is not a loophole, it is the
  # existing definition: the reverse proxy already treats a fourier_session
  # as signed in ("Signed-in readers carry the booru session cookie or the
  # fourier one"), and Technetium reads the booru with that session alone --
  # its live tag read, the CSRF scrape, the session card, sign-out. Everyone
  # signed in either way is untouched by this rule and gets exactly what they
  # got before.
  #
  # THE REFUSAL is raised from ApplicationController#refuse_anonymous_off_the_list,
  # right after the user is loaded and before anything else can answer, and
  # from GoodJob's dashboard controller (which does not inherit
  # ApplicationController). It is announced as anonymous_refused.members_only
  # so the routes-table test can tell this refusal from a 404 for a missing
  # record.
  #
  # FORMAT IS PART OF THE DOOR. A door names the formats it is open in, so
  # opening the post page did not also open /posts/1.json, and opening the
  # gallery did not open /posts.atom.
  #
  # NARROWED DOORS. Three pages a signed-out viewer needs would enumerate the
  # booru if they were simply open; each names the rule that narrows it:
  #
  #   :anonymous_post_listing  /posts is the newest posts and nothing else.
  #   :anonymous_shown_post    a post's page only for a post the site has
  #                            shown a signed-out viewer (anonymous_shown_post_ids).
  #   :anonymous_promoted_gallery  a creator's page only while the landing page
  #                            promotes it.
  #
  # The list, top to bottom. "Who calls it" is the reason the door exists.
  ANONYMOUS_DOORS = {
    # --- the front page ------------------------------------------------------
    "landing#show" => { formats: %i[html], why: "the front page, and the Open Graph tags a link unfurler (Discordbot) reads; its showcase is one fixed set per day for a signed-out viewer (LandingShowcase.anonymous_categories)" },
    "landing#preference" => { formats: %i[html], why: "the front page's 'Skip this next time' form; sets a cookie on this browser and redirects, names nothing" },
    "creator_galleries#show" => { formats: %i[html], narrow: :anonymous_promoted_gallery, why: "the front page's Promoted Creators section links each promoted creator's page" },
    "modulation#creator_activity" => { formats: %i[json], why: "creator_lamps.js re-reads the activity lamps on the front page's creator pills; booleans for names the caller sent" },

    # --- browsing: the newest posts, and the posts the site showed -----------
    "posts#index" => { formats: %i[html json], narrow: :anonymous_post_listing, why: "the gallery's first page (html), and fourier-auth's media visibility ask, GET /posts.json?tags=md5:... asked anonymously first (json)" },
    "posts#show" => { formats: %i[html], narrow: :anonymous_shown_post, why: "a slide or a gallery thumbnail clicked, and the hover tooltip (?variant=tooltip)" },
    "modulation#show" => { formats: %i[json], narrow: :anonymous_shown_post, why: "the post view's client-side move to the next post, for a post it may open" },
    "errors#show" => { formats: %i[svg], why: "the error card drawn in place of a picture that failed to load" },

    # --- signing in, signing out, registering, recovering ----------------------
    "sessions#new" => { formats: %i[html], why: "/login, and the popup login" },
    "sessions#create" => { formats: %i[html], why: "the login form's POST" },
    "sessions#verify_totp" => { formats: %i[html], why: "the second step of a 2FA login, before the session exists" },
    "sessions#done" => { formats: %i[html], why: "/login/done, where a popup login lands and closes itself" },
    "sessions#destroy" => { formats: :any, why: "sign out from a page whose session has already gone; the purge rectangle signs out first; names nothing" },
    "users#new" => { formats: %i[html], why: "the registration form an invite link opens (2026-09-11: refusing it broke registration for 16 hours)" },
    "users#create" => { formats: %i[html], why: "the registration form's POST" },
    "password_resets#show" => { formats: %i[html], why: "the 'forgot password' form" },
    "password_resets#create" => { formats: %i[html], why: "the 'forgot password' form's POST" },
    "password_resets#edit" => { formats: %i[html], why: "the reset link from the email, signed" },
    "password_resets#update" => { formats: %i[html], why: "the new password's POST, signed" },
    "emails#verify" => { formats: %i[html], why: "the verification link from the welcome email, opened wherever it is opened" },
    "maintenance/user/email_notifications#show" => { formats: %i[html], why: "the unsubscribe link in an email" },
    "maintenance/user/email_notifications#create" => { formats: :any, why: "one-click unsubscribe, POSTed by the mail provider (RFC 8058), signed" },
    "maintenance/user/email_notifications#destroy" => { formats: :any, why: "the unsubscribe link's DELETE form, signed" },
    "fourier_identity#show" => { formats: %i[json], why: "the login page's Matrix panel polls 'am I linked yet' before any session exists" },

    # --- the header's own chrome, on every page a signed-out viewer can see ---
    "modulation_session#status" => { formats: %i[json], why: "the Manage Session bar's monitors; reports only what the caller's own request proves" },
    "modulation_session#purge" => { formats: :any, why: "the purge rectangle, the server's half: expires this host's gate cookie and clears this origin's data" },
    "modulation_session#matrix_logout" => { formats: :any, why: "the session bar's sign-out, force-deleting the gate cookie on this host" },
    "modulation_settings#update" => { formats: %i[json], why: "the session bar's open state and the front page's hero band, kept in the signed-out viewer's own session" },
    "static#keyboard_shortcuts" => { formats: %i[html], why: "the '?' key's shortcut sheet" },

    # --- the footer, and what machines ask for ---------------------------------
    "static#terms_of_service" => { formats: %i[html], why: "the footer's Terms link (Privacy is PIP2 on 41chan.net, a router redirect)" },
    "static#contact" => { formats: %i[html], why: "the footer's Contact link" },
    "robots#index" => { formats: %i[text], why: "robots.txt, which crawlers read before anything else" },
    "health#show" => { formats: :any, why: "/up, the container health check" },
    "health#postgres" => { formats: :any, why: "/up/postgres, the database health check" },
    "health#redis" => { formats: :any, why: "/up/redis, the cache health check" },
  }.freeze

  # Is the default-deny rule in force? See the config switch for why it is
  # off under test.
  def default_deny?
    Danbooru.config.anonymous_default_deny?
  end

  # Signed out in every sense this site knows: no booru account (session or
  # API key) and no verified Matrix identity. `user` may be nil for an action
  # that loads no user (HealthController's anonymous_only).
  def signed_out?(user, request)
    !member?(user) && FourierIdentity.current(request).blank?
  end

  # The format a door is matched on. A browser asking for */* gets html, as
  # ApplicationController#set_variant decides it later; a format Rails does
  # not know matches nothing.
  def request_format(request)
    format = request.format
    return :html if format.nil? || format == Mime::ALL

    format.symbol
  end

  def door_for(controller_path, action_name)
    ANONYMOUS_DOORS["#{controller_path}##{action_name}"]
  end

  # Would a signed-out viewer get past the list to this door, in html? For a
  # link or a pill deciding whether to offer itself.
  def offers?(user, request, door)
    return true unless default_deny? && signed_out?(user, request)

    entry = ANONYMOUS_DOORS[door]
    entry.present? && entry[:narrow].nil? && (entry[:formats] == :any || entry[:formats].include?(:html))
  end

  # THE GATE. Refuse a signed-out viewer anything not on the list, in a format
  # the door is not open in, or outside a narrowed door's narrowing.
  def admit!(controller)
    return unless default_deny?

    request = controller.request
    return unless signed_out?(CurrentUser.user, request)

    key = "#{controller.controller_path}##{controller.action_name}"
    entry = ANONYMOUS_DOORS[key]
    refuse!(key, :off_the_list) if entry.nil?
    refuse!(key, :wrong_format) unless entry[:formats] == :any || entry[:formats].include?(request_format(request))
    refuse!(key, :narrowed) if entry[:narrow] && !send(entry[:narrow], controller)
  end

  def refuse!(key, why)
    ActiveSupport::Notifications.instrument("anonymous_refused.members_only", door: key, why: why)
    raise ActiveRecord::RecordNotFound
  end

  # --- the narrowings ----------------------------------------------------------

  # /posts for a signed-out viewer is THE NEWEST POSTS AND NOTHING ELSE.
  #
  # The browsing cap held them to "page 1", but a tag query is a page 1 of
  # its own: /posts?tags=id:1..20, then id:21..40, walks the whole booru
  # without ever leaving page 1, and so does page=b<id> (sequential paging
  # reads as page 1 to the cap). Measured on production 2026-10-07 as a
  # signed-out visitor: id:1..20, id:21..40, order:random and page=b878000
  # all answered 200.
  #
  # What a signed-out viewer may pass, exactly:
  #   - no tags at all (`tags`, `post[tags]` blank) -- the newest posts;
  #   - page blank or 1; limit (clamped to restricted_browsing_per_page as
  #     for anyone below the browsing tier); size, show_votes, variant;
  #   - in json ONLY, `tags=md5:<32 hex>[,<32 hex>...]` (up to the 20 rows a
  #     restricted page holds) and no other term: fourier-auth's
  #     media gate asks exactly that, anonymously, before every picture it
  #     releases, and treats any non-200 as "booru unavailable" -- refusing
  #     it would black out every picture for everyone. An md5 is not
  #     enumerable the way an id is: it names one file the caller already has.
  # Not `md5=` (a redirect to the post page), not `random=`. The Modulation
  # panel's remembered sort is not applied for them either (PostsController).
  ANONYMOUS_MD5_QUERY = /\Amd5:[0-9a-f]{32}(,[0-9a-f]{32}){0,19}\z/i

  def anonymous_post_listing(controller)
    params = controller.params
    tags = (params[:tags].presence || params.dig(:post, :tags)).to_s.strip
    page = params[:page].to_s.strip
    return false unless page.empty? || page == "1"
    return false if params[:md5].present? || params[:random].present?
    return true if tags.empty?

    request_format(controller.request) == :json && tags.match?(ANONYMOUS_MD5_QUERY)
  end

  # A post's page for a post the site has shown a signed-out viewer: on the
  # gallery's first page within the last hour or two, in today's front-page
  # set, or in a promoted creator's curated set. Walking /posts/1, /posts/2...
  # was the same enumeration by another door (every id answered 200 on
  # 2026-10-07); a page reached from what the site showed still opens.
  def anonymous_shown_post(controller)
    id = Integer((controller.params[:id] || controller.params[:post_id]).to_s, 10, exception: false)
    id.present? && anonymous_shown_post?(id, safe_mode: CurrentUser.safe_mode?)
  end

  def anonymous_shown_post?(id, safe_mode:)
    anonymous_recent_listing_ids(safe_mode).include?(id) ||
      anonymous_newest_ids(safe_mode).include?(id) ||
      LandingShowcase.anonymous_post_ids(safe_mode: safe_mode).include?(id) ||
      promoted_gallery_post_ids.include?(id)
  end

  # A creator's page while the front page promotes it, and no other: the
  # promoted section links there. Its posts are its curated set, a bounded
  # pick the creator made to be shown.
  def anonymous_promoted_gallery(controller)
    CreatorGallery.landing_promoted.where(slug: controller.params[:slug].to_s).exists?
  end

  def promoted_gallery_post_ids
    CreatorGalleryPost.where(creator_gallery_id: CreatorGallery.landing_promoted.select(:id)).pluck(:post_id).to_set
  end

  # THE GALLERY'S FIRST PAGE, AS SHOWN. PostsController records the ids it
  # rendered for a signed-out viewer, into an hourly bucket; a post page reads
  # this hour's and the last, so a thumbnail clicked minutes after the page
  # loaded still opens after newer posts have pushed it off the first page.
  # Nothing here can be reached that the gallery did not render.
  RECENT_LISTING_TTL = 2.hours

  def recent_listing_key(safe_mode, at)
    ["members_only", "anonymous_listing", safe_mode ? "safe" : "all", at.utc.strftime("%Y%m%d%H")]
  end

  def remember_anonymous_listing(ids, safe_mode:, now: Time.now)
    key = recent_listing_key(safe_mode, now)
    Rails.cache.write(key, (Rails.cache.read(key).to_a | ids.to_a).last(2_000), expires_in: RECENT_LISTING_TTL)
  end

  def anonymous_recent_listing_ids(safe_mode, now: Time.now)
    [now, now - 1.hour].flat_map { |at| Rails.cache.read(recent_listing_key(safe_mode, at)).to_a }.to_set
  end

  # The gallery's first page as it is now, for a link opened without the
  # gallery having been loaded (a member's link opened signed out). Thirty
  # seconds of cache: a crawler walking ids must not cost a search each.
  def anonymous_newest_ids(safe_mode)
    Rails.cache.fetch(["members_only", "anonymous_newest", safe_mode ? "safe" : "all"], expires_in: 30.seconds) do
      PostSets::Post.new(nil, 1, user: User.anonymous).posts.map(&:id)
    end.to_set
  end
end
