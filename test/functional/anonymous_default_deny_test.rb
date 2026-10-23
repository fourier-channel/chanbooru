# frozen_string_literal: true

require "test_helper"

# DEFAULT-DENY for a signed-out viewer (operator, 2026-10-07: "I'm trying to
# solidify the view surfaces and keep finding new ways for danbooru to show
# every single post to whoever bothered to ask."). The rule and the list are
# MembersOnly::ANONYMOUS_DOORS; the switch is off under test (the fork
# restriction pattern), so this file stubs it on and is where it is proven.
#
# THE GUARD AGAINST THE NEXT LEAK is the walk: every route in the table, the
# GoodJob engine's included, asked as a signed-out viewer. Each answer must be
# the gate's own refusal (announced as anonymous_refused.members_only, so a
# 404 for a missing record cannot pass for one) unless the door it reached is
# on the list. A route added later is walked without anyone listing it here;
# a controller that skips the gate, or a mounted app that never meets it, is
# what fails.
class AnonymousDefaultDenyTest < ActionDispatch::IntegrationTest
  REFUSED = "anonymous_refused.members_only"

  # Route-level redirects answer before any controller runs and carry no
  # content of their own; their targets are walked as routes, and followed
  # below. This one leaves the host.
  EXTERNAL_REDIRECTS = %w[https://41chan.net/pip2.html].freeze

  # One concrete path per route. Optional groups are dropped; a segment with
  # a requirement gets the first candidate it accepts.
  CANDIDATES = %w[1 404 svg].freeze

  def expand(route, prefix = "")
    spec = route.path.spec.to_s
    spec = spec.gsub(/\([^()]*\)/, "") while spec.include?("(")
    path = spec.gsub(/\*(\w+)/, "anything").gsub(/:(\w+)/) do
      requirement = route.requirements[::Regexp.last_match(1).to_sym]
      requirement.is_a?(Regexp) ? CANDIDATES.find { |c| c.match?(/\A(?:#{requirement.source})\z/) } || "1" : "1"
    end
    path += ".svg" if route.requirements[:format].is_a?(Regexp) && "svg".match?(route.requirements[:format])
    "#{prefix}#{path}".squeeze("/").presence || "/"
  end

  # Routes that exist only under test and development, so are not doors in
  # production: ViewComponent draws its previews (`internal: true`) and its
  # system-test entrypoint only when Rails.env is development or test
  # (view_component engine.rb, previews.enabled's default).
  def only_under_test?(route)
    route.internal || route.path.spec.to_s.start_with?("/_system_test_entrypoint")
  end

  # A route to an action its controller does not have: Rails answers 404
  # (AbstractController::ActionNotFound) before any filter runs, so nothing
  # is there to refuse. upstream draws several (`resources :counts` has only
  # `posts`).
  def dead?(door)
    controller, action = door.split("#", 2)
    klass = "#{controller}_controller".camelize.safe_constantize
    klass.present? && !klass.new.available_action?(action)
  end

  # [verb, path] for every route: the application's and every mounted
  # engine's, a route with no verb (a mount, the catch-all) as GET.
  def walk_list
    Rails.application.routes.routes.reject { |r| only_under_test?(r) }.flat_map do |route|
      app = route.app.respond_to?(:app) ? route.app.app : route.app
      if app.is_a?(Class) && app < Rails::Engine
        prefix = route.path.spec.to_s
        app.routes.routes.flat_map { |r| verbs(r).map { |v| [v, expand(r, prefix)] } }
      else
        verbs(route).map { |v| [v, expand(route)] }
      end
    end.uniq
  end

  def verbs(route)
    list = route.verb.to_s.split("|").presence || ["GET"]
    list - ["TRACE"]
  end

  # Ask once; return [status, the door Rails dispatched to (nil for a
  # route-level redirect), the refusals the gate announced].
  def ask(verb, path, headers: {})
    refusals = []
    callback = ->(*, payload) { refusals << payload }
    ActiveSupport::Notifications.subscribed(callback, REFUSED) do
      process(verb.downcase.to_sym, path, headers: headers)
    rescue StandardError => e
      # Raised through every handler: the gate did not answer, something else
      # failed first. Reported as what it is.
      return [e.class.name, "raised #{e.message.truncate(120)}", refusals]
    end
    params = request.path_parameters
    door = params[:controller] && "#{params[:controller]}##{params[:action]}"
    [response.status, door, refusals]
  end

  def listed?(door) = MembersOnly::ANONYMOUS_DOORS.key?(door)

  def refused_here?(status, door, refusals)
    status == 404 && refusals.any? { |r| r[:door] == door }
  end

  def assert_refused(path, why: nil, headers: {}, verb: "GET")
    status, door, refusals = ask(verb, path, headers: headers)
    assert(refused_here?(status, door, refusals), "#{verb} #{path} should be refused by the gate; got #{status} at #{door.inspect}, refusals #{refusals.inspect}")
    assert_equal(why, refusals.last[:why], "#{path}: refused for the wrong reason") if why
  end

  def assert_admitted(path, status: 200, headers: {})
    got, door, refusals = ask("GET", path, headers: headers)
    assert_empty(refusals, "#{path} at #{door}: should not be refused")
    assert_equal(status, got, "#{path} at #{door}")
  end

  def matrix(mxid = "@reader:41chan.net") = { "X-Fourier-Identity" => mxid }

  # The post ids a front-page answer (/landing/slides.json) carries.
  def slide_ids(body = response.parsed_body)
    body["categories"].flat_map { |c| c["slides"].pluck("id") }
  end

  # The GET walk as whoever this session is, for comparing the rule on and
  # off. Post-shaped paths get a real post so the comparison is not 404
  # against 404 throughout.
  def statuses(headers: {})
    walk_list.select { |verb, _| verb == "GET" }.to_h do |_verb, path|
      path = path.sub(%r{\A/posts/1(?=/|\z)}, "/posts/#{@post.id}")
      begin
        process(:get, path, headers: headers)
        [path, response.status]
      rescue StandardError => e
        [path, e.class.name]
      end
    end
  end

  setup do
    Rails.cache.clear
    Danbooru.config.stubs(:anonymous_default_deny?).returns(true)
  end

  context "The routes table, walked signed out" do
    should "refuse every GET door off the list with the gate's own 404" do
      leaks = []
      walked = 0
      walk_list.select { |verb, _| verb == "GET" }.each do |verb, path|
        status, door, refusals = ask(verb, path)
        walked += 1
        if door.nil?
          # A route-level redirect: no controller ran. Follow it once.
          location = response.location.to_s
          next if EXTERNAL_REDIRECTS.include?(location)

          unless response.redirect?
            leaks << "#{path}: #{status} with no controller and no redirect"
            next
          end
          uri = URI.parse(location)
          if uri.host.present? && uri.host != host
            leaks << "#{path}: redirects off the host to #{location}"
            next
          end
          status, door, refusals = ask("GET", uri.request_uri)
          if door.nil?
            leaks << "#{path} -> #{uri.request_uri}: #{status} with no controller"
            next
          end
        end
        next if listed?(door)
        next if status == 404 && dead?(door)

        leaks << "#{verb} #{path} -> #{door}: #{status}, refusals #{refusals.inspect}" unless refused_here?(status, door, refusals)
      end

      assert_operator(walked, :>, 300, "the walk found too few routes to trust")
      assert_empty(leaks, "doors a signed-out viewer reached off the list:\n#{leaks.join("\n")}")
    end

    should "refuse every non-GET door off the list with the gate's own 404" do
      leaks = []
      walk_list.reject { |verb, _| verb == "GET" }.each do |verb, path|
        status, door, refusals = ask(verb, path)
        next if door && listed?(door)
        next if door && status == 404 && dead?(door)

        leaks << "#{verb} #{path} -> #{door.inspect}: #{status}, refusals #{refusals.inspect}" unless door && refused_here?(status, door, refusals)
      end
      assert_empty(leaks, "doors a signed-out viewer reached off the list:\n#{leaks.join("\n")}")
    end

    should "list only doors that exist, each with a reason and a real narrowing" do
      routed = Rails.application.routes.routes.filter_map { |r| r.defaults[:controller] && "#{r.defaults[:controller]}##{r.defaults[:action]}" }.to_set
      MembersOnly::ANONYMOUS_DOORS.each do |door, entry|
        assert_includes(routed, door, "#{door} is listed but no route reaches it -- a stale entry")
        assert(entry[:why].to_s.strip.length > 10, "#{door} needs its reason")
        assert(entry[:formats] == :any || (entry[:formats].is_a?(Array) && entry[:formats].any?), "#{door} names no format")
        assert(MembersOnly.respond_to?(entry[:narrow]), "#{door} narrows by #{entry[:narrow]}, which does not exist") if entry[:narrow]
      end
    end

    should "refuse a listed door in a format it is not open in" do
      checked = 0
      MembersOnly::ANONYMOUS_DOORS.each do |door, entry|
        next if entry[:formats] == :any

        route = Rails.application.routes.routes.find { |r| "#{r.defaults[:controller]}##{r.defaults[:action]}" == door && r.verb == "GET" && r.path.spec.to_s.include?("(.:format)") }
        next unless route
        next if route.requirements[:format] # the route itself fixes the format

        other = (%i[json html atom] - entry[:formats]).first
        path = expand(route)
        assert_refused("#{path}.#{other}", why: :wrong_format)
        checked += 1
      end
      assert_operator(checked, :>=, 15)
    end
  end

  context "A signed-in viewer, across the routes table" do
    setup do
      @member = create(:user, created_at: 1.month.ago)
      @post = create(:post)
    end

    should "get exactly what it got with the rule off, as a booru member" do
      login_as(@member)
      on = statuses
      Danbooru.config.stubs(:anonymous_default_deny?).returns(false)
      reset!
      login_as(@member)
      off = statuses
      assert_equal(off, on)
      assert_operator(on.values.count(200), :>=, 60, "too few doors answered a member to make the comparison mean anything")
    end

    should "get exactly what it got with the rule off, signed in with Matrix alone" do
      on = statuses(headers: matrix)
      Danbooru.config.stubs(:anonymous_default_deny?).returns(false)
      reset!
      off = statuses(headers: matrix)
      assert_equal(off, on)
    end
  end

  context "The doors that stay open, signed out" do
    setup do
      # Real md5s: the factory's are 64 hex characters, and the md5 door
      # admits only what an md5 is.
      @old = create(:post, created_at: 2.days.ago, md5: SecureRandom.hex(16))
      @newest = Array.new(21) { create(:post, md5: SecureRandom.hex(16)) }.last
    end

    # The front page is the anonymous draw ON PURPOSE (operator, 2026-10-08:
    # "The landing carousel was the Anonymous draw, purposely. It let me
    # choose creators to show off without opening the whole booru."). Its
    # scope is the operator's own choice of rows, so it is live for a
    # signed-out viewer exactly as for a member.
    should "serve the front page live, with /landing/slides to poll" do
      assert_admitted root_path
      assert_match(%r{landing/slides}, response.body)
      assert_admitted "/landing/slides.json"
      first = slide_ids
      assert(first.any?, "the showcase drew nothing, so this proves nothing")

      later = create(:post, md5: SecureRandom.hex(16), fav_count: 1_000)
      assert_admitted "/landing/slides.json"
      assert_includes(slide_ids, later.id, "a signed-out draw must be live, not frozen")
    end

    should "open a slide's post page only once a signed-out viewer was served it" do
      # Top of Community Favorites, and too old for the gallery's first page
      # (which is newest by id: twenty-one posts came after it).
      favourite = @old
      favourite.update_columns(fav_count: 1_000)
      assert_refused post_path(favourite), why: :narrowed
      assert_refused "/posts/#{favourite.id}/modulation.json", why: :narrowed

      assert_admitted "/landing/slides.json"
      assert_includes(slide_ids, favourite.id)
      assert_admitted post_path(favourite)
      assert_admitted "/posts/#{favourite.id}/modulation.json"
    end

    should "open the front page's own slides from the page, not only from the poll" do
      favourite = @old
      favourite.update_columns(fav_count: 1_000)
      assert_refused post_path(favourite), why: :narrowed
      assert_admitted root_path
      assert_admitted post_path(favourite)
    end

    context "with a featured creators row" do
      setup do
        @artist = create(:tag, name: "featured_maker", category: Tag.categories.artist)
        create(:tag, name: "unfeatured_maker", category: Tag.categories.artist)
        LandingCategory.create!(key: "featured", label: "Featured Creators", enabled: true, position: 0,
                                kind: "tags", tags: ["featured_maker"], ordering: "new", fresh_only: false)
        # Twelve by the featured creator, all older than the gallery's first
        # page; the row shows ten of them, the tag page all twelve.
        @made = Array.new(12) { |i| create(:post, tag_string: "featured_maker", created_at: (10 + i).days.ago, md5: SecureRandom.hex(16)) }
        create(:post, tag_string: "unfeatured_maker", created_at: 9.days.ago, md5: SecureRandom.hex(16))
        # The gallery's first page is newest by id: push these off it.
        21.times { create(:post, md5: SecureRandom.hex(16)) }
      end

      should "link a featured creator's pill and leave every other pill unlinked" do
        assert_admitted "/landing/slides.json"
        creators = response.parsed_body["categories"].flat_map { |c| c["slides"].pluck("creator") }.compact
        featured = creators.select { |c| c["tag"] == "featured_maker" }
        assert(featured.any?, "the featured row drew nothing")
        assert(featured.all? { |c| c["url"] == posts_path(tags: "featured_maker") }, featured.inspect)
        others = creators.reject { |c| c["tag"] == "featured_maker" }
        assert(others.any?, "no other pill to check")
        assert(others.all? { |c| c["url"].nil? }, others.inspect)

        login_as(create(:user))
        get "/landing/slides.json"
        member = response.parsed_body["categories"].flat_map { |c| c["slides"].pluck("creator") }.compact
        assert(member.reject { |c| c["tag"] == "featured_maker" }.all? { |c| c["url"].present? }, "a member's pills lost their links")
      end

      should "open a featured creator's tag page 1 and nothing else" do
        assert_admitted "#{posts_path}?tags=featured_maker"
        ["tags=featured_maker+1girl", "tags=featured_maker+order:random",
         "tags=unfeatured_maker", "tags=-featured_maker"].each do |query|
          assert_refused "#{posts_path}?#{query}", why: :narrowed
        end
        # Past page 1 is the browsing tier's to refuse (410), not this rule's.
        ["tags=featured_maker&page=2", "tags=featured_maker&page=b#{@made.first.id}",
         "tags=featured_maker&preset=modulation&anchor=#{@made.first.id}", "tags=featured_maker&preset=modulation&before=#{@made.last.id}",
         "tags=featured_maker&preset=modulation&variant=window&anchor=#{@made.first.id}"].each do |query|
          assert_admitted "#{posts_path}?#{query}", status: 410
        end
        assert_refused "/posts.json?tags=featured_maker", why: :narrowed
        assert_refused "/posts.atom?tags=featured_maker", why: :wrong_format
      end

      should "open the posts on a featured creator's page once it was shown" do
        oldest = @made.last
        assert_refused post_path(oldest), why: :narrowed
        get "#{posts_path}?tags=featured_maker"
        assert_response 200
        assert_admitted post_path(oldest)
      end

      should "close a creator's page again when the row is disabled" do
        LandingCategory.find_by!(key: "featured").update!(enabled: false)
        assert_refused "#{posts_path}?tags=featured_maker", why: :narrowed
      end
    end

    should "let a signed-out visitor choose the gallery as their front page" do
      post landing_preference_path, params: { landing: "gallery" }
      assert_redirected_to posts_path
    end

    should "let a stranger register with an invite and then be a member" do
      Danbooru.config.stubs(:enable_signup?).returns(false)
      Danbooru.config.stubs(:signup_requires_token?).returns(true)
      SignupToken.create!(token: "WALKTHROUGH12", creator: create(:admin_user))

      assert_admitted new_user_path
      assert_difference("User.count", 1) do
        post users_path, params: { user: { name: "walker#{rand(1_000_000)}", password: "hunter22longenough", password_confirmation: "hunter22longenough", signup_token: "WALKTHROUGH12" } }
      end
      assert_response :redirect
      assert_admitted artists_path
    end

    should "let a member sign in, and sign out again" do
      user = create(:user)
      assert_admitted login_path
      assert_admitted login_done_path
      post session_path, params: { session: { name: user.name, password: user.password } }
      assert_response :redirect
      assert_admitted tags_path
      delete session_path
      assert_response 303
      assert_refused tags_path
    end

    should "open the recovery and machine doors" do
      assert_admitted password_reset_path
      assert_admitted "/fourier_identity.json"
      assert_admitted "/robots.txt"
      assert_admitted "/up", status: 204
      assert_admitted terms_of_service_path
      assert_admitted "/errors/404.svg"
      assert_admitted "/modulation/session_status.json"
    end

    should "show the newest posts and nothing else on /posts" do
      assert_admitted posts_path
      assert_admitted "#{posts_path}?page=1"
      assert_admitted "/posts.json"
      ["tags=id:1..20", "tags=id:21..40", "tags=order:random", "tags=1girl", "post[tags]=id:1..20",
       "random=1", "md5=#{@old.md5}"].each do |query|
        assert_refused "#{posts_path}?#{query}", why: :narrowed
      end
      # Past page 1 -- a page, a cursor, the window's anchor or before -- is
      # the browsing tier's to refuse (410), for every viewer below it.
      ["page=2", "page=b#{@newest.id}", "page=a1",
       "preset=modulation&anchor=#{@newest.id}", "preset=modulation&anchor=#{@newest.id}~#{@newest.id}", "preset=modulation&anchor=@20",
       "preset=modulation&before=#{@newest.id}", "preset=modulation&variant=window&anchor=#{@newest.id}"].each do |query|
        assert_admitted "#{posts_path}?#{query}", status: 410
      end
      assert_refused "/posts.atom", why: :wrong_format
      assert_refused "/posts.json?tags=md5:#{@old.md5}+id:1..20", why: :narrowed
      assert_refused "#{posts_path}?tags=md5:#{@old.md5}", why: :narrowed
    end

    # Operator, 2026-10-13/14: a signed-out visitor's IMAGE follows the post's
    # PAGE (gate 10). fourier-auth's anonymous ask is answered with a row only
    # for a post the site has shown signed out -- the set that opens
    # /posts/<id> signed out -- and every other md5 is absent, gated or not.
    # fourier-auth reads absence as refused and asks again as the reader's
    # own booru session, so a signed-in reader is unaffected.
    should "answer fourier-auth's anonymous md5 ask only for posts the site showed signed out" do
      gated = create(:post, tag_string: "aaaa child", md5: SecureRandom.hex(16))
      ask = lambda do |*posts|
        get "/posts.json", params: { tags: "md5:#{posts.map(&:md5).join(",")}", only: "md5,is_deleted,source", limit: posts.size }
        assert_response 200
        response.parsed_body
      end

      rows = ask.call(@old, @newest, gated)
      assert_equal([@newest.md5], rows.pluck("md5"))
      assert_equal(%w[is_deleted md5 source], rows.flat_map(&:keys).uniq.sort)
      # Asking for it by md5 does not make the old post's page one the site
      # showed a signed-out viewer.
      assert_refused post_path(@old), why: :narrowed

      # A gated post has no row even if its id were somehow remembered as
      # shown: the signed-out search excludes it before the shown set is read.
      MembersOnly.remember_shown_to_anonymous([gated.id], safe_mode: false)
      assert_equal([], ask.call(gated))

      # Signed in, the same ask is the reader's own: the old post is theirs to see.
      login_as(create(:user, created_at: 1.month.ago))
      assert_equal([@old.md5], ask.call(@old).pluck("md5"))
    end

    # The ask carries no safe mode, so both modes' shown sets count: the
    # hourly buckets of each and the newest page of each. A promoted
    # creator's posts count once their page DREW them for a signed-out viewer
    # (Creator Gallery rebuild, 2026-10-23): a curated post the page did not
    # draw -- no longer fitting its band, made private since -- is never
    # granted, where the old curated-set grant opened it for good.
    should "count a post shown in either safe mode, or drawn on a promoted creator's page, in the md5 ask" do
      gallery = create(:creator_gallery, promoted_at: Time.current, settings: { "hero" => { "tags" => %w[drawn_band] }})
      safe_shown, all_shown = Array.new(2) { create(:post, md5: SecureRandom.hex(16)) }
      drawn = create(:post, md5: SecureRandom.hex(16), tag_string: "drawn_band")
      undrawn = create(:post, md5: SecureRandom.hex(16), tag_string: "other_band")
      [drawn, undrawn].each_with_index do |post, i|
        FourierPostCreator.create!(post: post, mxid: gallery.matrix_id, recorded_by: post.uploader_id)
        CreatorGalleryPost.create!(creator_gallery: gallery, post: post, position: i)
      end
      create_list(:post, 21) # rubocop:disable FactoryBot/ExcessiveCreateList -- all four are off the newest page now
      MembersOnly.remember_shown_to_anonymous([safe_shown.id], safe_mode: true)
      MembersOnly.remember_shown_to_anonymous([all_shown.id], safe_mode: false)
      ask = lambda do
        md5s = [@old, safe_shown, all_shown, drawn, undrawn].map(&:md5)
        get "/posts.json", params: { tags: "md5:#{md5s.join(",")}", only: "md5,is_deleted,source", limit: 5 }
        assert_response 200
        response.parsed_body.pluck("md5").sort
      end

      assert_equal([safe_shown, all_shown].map(&:md5).sort, ask.call)
      assert_admitted creator_gallery_path(gallery)
      assert_equal([safe_shown, all_shown, drawn].map(&:md5).sort, ask.call)
      assert_admitted post_path(drawn)
      assert_refused post_path(undrawn), why: :narrowed
    end

    # The Promoted Creators card's picture is the gallery's hero band as its
    # own page draws it, and the front page grants it as it grants a slide:
    # with the carousel's galleries row off, the card is the only way in. A
    # first row the page would not draw -- private, or not fitting the band --
    # is never the picture.
    should "grant a signed-out visitor the promoted card's picture, the hero band's first drawn post" do
      LandingCategory.create!(LandingCategory::DEFAULTS.find { it[:kind] == "galleries" }.merge(enabled: false))
      gallery = create(:creator_gallery, promoted_at: Time.current, settings: { "hero" => { "tags" => %w[drawn_band] }})
      veiled, stray, drawn = %w[drawn_band other_band drawn_band].map { |tags| create(:post, md5: SecureRandom.hex(16), tag_string: tags) }
      [veiled, stray, drawn].each_with_index do |post, i|
        FourierPostCreator.create!(post: post, mxid: gallery.matrix_id, recorded_by: post.uploader_id)
        CreatorGalleryPost.create!(creator_gallery: gallery, post: post, position: i)
      end
      CreatorPostAudience.set!(veiled, gallery: gallery, audience: "private", by: create(:admin_user))
      create_list(:post, 21) # rubocop:disable FactoryBot/ExcessiveCreateList -- all three are off the newest page now

      get root_path
      assert_response 200
      assert_select ".modland-promoted-card .mod-blacklist-target[data-id=?]", drawn.id.to_s, 1
      assert_select ".modland-promoted-card .mod-blacklist-target", 1
      shown = MembersOnly.anonymous_recent_shown_ids(false) | MembersOnly.anonymous_recent_shown_ids(true)
      assert_includes(shown, drawn.id)
      assert_not_includes(shown, veiled.id)
      assert_not_includes(shown, stray.id)
      assert_admitted post_path(drawn)
    end

    # Each mode's newest page is that mode's, whatever mode the asking
    # request is in: an explicit post on the newest page is in the "all"
    # set and not the safe one.
    should "read each safe mode's newest page in that mode" do
      explicit = create(:post, rating: "e", md5: SecureRandom.hex(16))
      CurrentUser.set(user: User.anonymous, safe_mode: false) do
        assert_not_includes MembersOnly.anonymous_newest_ids(true), explicit.id
        assert_includes MembersOnly.anonymous_newest_ids(false), explicit.id
      end
      Rails.cache.clear
      CurrentUser.set(user: User.anonymous, safe_mode: true) do
        assert_includes MembersOnly.anonymous_newest_ids(false), explicit.id
        assert_not_includes MembersOnly.anonymous_newest_ids(true), explicit.id
      end
    end

    # An md5 is not a secret (4chan's archives publish one for every image),
    # so an md5 ask that could choose its own fields would read any post's
    # tags twenty at a time. It is fourier-auth's ask, field for field, or
    # nothing (booru-visibility.js: only=md5,is_deleted,source).
    should "refuse an md5 ask for anything but fourier-auth's three fields" do
      md5s = "md5:#{@old.md5},#{@newest.md5}"
      [{ only: "id,tag_string" }, { only: "md5,is_deleted,source,tag_string" }, { only: "md5" }, {},
       { only: "md5,is_deleted,source", search: { id: 1 } }, { only: "md5,is_deleted,source", includes: "uploader" },
       { only: "md5,is_deleted,source[tag_string]" }].each do |extra|
        query = { tags: md5s, limit: 2 }.merge(extra).to_query
        assert_refused "/posts.json?#{query}", why: :narrowed
      end
      assert_admitted "/posts.json?#{{ tags: md5s, only: "source,md5,is_deleted" }.to_query}"
    end

    should "open a post page only for a post the site showed a signed-out viewer" do
      assert_refused post_path(@old), why: :narrowed
      assert_refused "/posts/#{@old.id}/modulation.json", why: :narrowed
      assert_admitted post_path(@newest)
      assert_admitted "/posts/#{@newest.id}/modulation.json"

      # Shown on the gallery's first page, then pushed off it by newer posts:
      # a thumbnail clicked minutes later still opens.
      get posts_path
      shown = Post.order(id: :desc).limit(20).last
      create_list(:post, 21)
      assert_admitted post_path(shown)
      assert_refused post_path(@old), why: :narrowed
    end

    should "open a creator's page only while the front page promotes it" do
      gallery = create(:creator_gallery)
      assert_refused creator_gallery_path(gallery), why: :narrowed
      gallery.update!(promoted_at: Time.current)
      assert_admitted creator_gallery_path(gallery)
    end

    should "not offer a signed-out visitor nav pills that would answer not found" do
      get posts_path(preset: "modulation")
      assert_response 200
      nav = response.body[%r{<header id="top".*?</header>}m].to_s
      assert_operator(nav.length, :>, 100, "the header was not found in the page")
      [artists_path, tags_path, wiki_pages_path, site_map_path].each { |path| assert_no_match(/href="#{Regexp.escape(path)}"/, nav) }
      assert_match(/href="#{Regexp.escape(posts_path)}"/, nav)
    end

    should "leave the gate's media and sign-in routes to fourier-auth, never Rails" do
      # /fourier/exchange, /fourier/login, /fourier/logout and the media door
      # are fourier-auth's: nginx hands the whole prefix over before Rails is
      # asked, so this list never has to open them.
      nginx = Rails.root.join("config/nginx.conf").read
      assert_match(%r{location /fourier/ \{\s*set \$fourier_auth http://fourier-auth:8010;}, nginx)
    end
  end

  context "The doors that remain refused, signed out" do
    setup do
      @post = create(:post)
      as(create(:user)) { create(:artist_commentary, post: @post) }
    end

    should "refuse the inventory of 2026-10-07" do
      ["/artist_commentaries/1", "/artist_commentary_versions/1", "/post_approvals/1", "/post_flags/1",
       "/post_appeals/1", "/post_disapprovals/1", "/post_replacements/1", "/reactions/1", "/user_actions/1",
       "/pool_versions/1/diff", "/post_votes/1", "/mod_actions/1", "/artists/1", "/artists", "/wiki_pages/1",
       "/creators/anyone", "/creators", "/tags", "/tags.json", "/counts/posts?tags=rating:e", "/related_tag?query=1girl",
       "/autocomplete.json?search[query]=a&search[type]=tag_query", "/reports/posts", "/users/1", "/users",
       "/posts/#{@post.id}.json", "/posts/#{@post.id}/tag_sources.json", "/posts/#{@post.id}/artist_commentary.json",
       "/post/index.json", "/tag/index.json", "/static/site_map", "/source.json", "/good_job/jobs"].each do |path|
        assert_refused path
      end
    end
  end

  context "Signed in by other means" do
    setup do
      @post = create(:post)
    end

    should "let a verified Matrix identity read as before, Technetium's tag read included" do
      assert_admitted "/posts/#{@post.id}/tag_sources.json", headers: matrix
      assert_admitted "#{posts_path}?tags=id:1..20", headers: matrix
      assert_admitted "/static/site_map", headers: matrix
    end

    should "let a bot with an API key through" do
      bot = create(:builder_user)
      key = create(:api_key, user: bot)
      assert_admitted "/posts.json?tags=id:1..20&login=#{bot.name}&api_key=#{key.key}"
      assert_admitted "/creator_prefixes.json?login=#{bot.name}&api_key=#{key.key}"
    end
  end

  context "With the rule as the inherited suite runs it (off under test)" do
    should "list for a signed-out visitor as upstream does" do
      Danbooru.config.unstub(:anonymous_default_deny?)
      get tags_path
      assert_response :success
      get "#{posts_path}?tags=id:1..20"
      assert_response :success
    end
  end
end
