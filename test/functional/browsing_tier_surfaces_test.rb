# frozen_string_literal: true

require "test_helper"

# THE BROWSING TIER, WALKED ACROSS EVERY SURFACE (ACCOUNT_LIMITS.md 5.1).
#
# Operator, 2026-10-17: "If an account has a certain limit on one surface it
# should have that limit across all surfaces." And 2026-10-18: every listing,
# not only lists of posts. Below full browsing -- a Restricted account, a
# signed-out visitor, a Matrix-only reader -- every list is one page of at most
# restricted_browsing_per_page records, with no cursor and no walking.
#
# HOW IT IS MEASURED. restricted_browsing_per_page is stubbed to CAP, and every
# list gets MORE fixture records of its own kind than CAP, so a `limit=1000`
# that is not clamped shows more than CAP of them. Each list's extractor
# counts its own fixture records -- by id, in the parsed JSON or in the HTML
# elements that list draws -- and is checked once against a full account,
# where it must see more than CAP: an extractor that sees nothing would pass
# the clamp vacuously, and here it fails instead.
#
# THE GUARD AGAINST THE NEXT SURFACE is ROUTES: every GET route is classified,
# and a list of anything must be a SURFACES row, so its bound is walked here.
# A route added later and left out fails the completeness test, by name.
#
# MembersOnly's switches are off under test, so the tier is the thing being
# measured; the last context turns them on and shows the two rules compose.
class BrowsingTierSurfacesTest < ActionDispatch::IntegrationTest
  CAP = 2
  # More of each than CAP: a list whose fixtures do not exceed the cap cannot
  # fail the limit probe.
  N = 5
  MXID = "@tier-reader:41chan.net"
  CURSOR_PROBES = { "page=2" => { page: 2 }, "page=b<max>" => { page: "b999999999" }, "page=a0" => { page: "a0" }}.freeze

  # One row per list. path: [path, params] (no format suffix); formats: what
  # it serves (the first two are counted, every one is probed); count: the
  # extractor, which returns how many of the row's fixture records the body
  # names; kind:
  #   :listing -- paged: cursor probes answer 410, limit=1000 is clamped
  #   :unpaged -- a list with a size and no pages: limit=1000 is clamped
  #   :whole   -- a list with no size parameter: what it shows is clamped
  #   :walk    -- post-to-post: `expect: 410` is refused; `expect: :drawn`
  #               is a 200 page drawn with no neighbour links
  # viewers: the capped viewers it applies to (own-only lists: Restricted).
  # blind: the capped viewers who rightly see none of the row's fixtures, with
  # why -- any other 200 that shows none is an extractor or a surface gone
  # blind, and fails. A Restricted account sees exactly CAP.
  SURFACES = {
    # --- lists of posts (ACCOUNT_LIMITS.md section 3) ---
    posts: { path: -> { ["/posts", { tags: "tierfix_tag", preset: "historical" }] }, formats: %i[html json xml atom], count: :posts, window: true },
    legacy_posts: { path: -> { ["/post/index", { tags: "tierfix_tag" }] }, formats: %i[json xml], count: :posts },
    explore_popular: { path: -> { ["/explore/posts/popular", {}] }, formats: %i[html json xml], count: :posts },
    pool: { path: -> { ["/pools/#{@pools.first.id}", {}] }, formats: %i[html json], count: :pool_posts },
    pools_gallery: { path: -> { ["/pools/gallery", {}] }, formats: %i[html json], count: -> { @json ? rows(Pool, Pool.ids) : (linked_ids("pools") & Pool.ids).size }},
    pools: { path: -> { ["/pools", {}] }, formats: %i[html json], count: -> { rows(Pool, Pool.ids) }},
    pools_arrays: { path: -> { ["/pools", {}] }, formats: %i[json], count: -> { widest_array("post_ids", @pools.map(&:id)) }},
    favorite_groups: { path: -> { ["/favorite_groups", {}] }, formats: %i[html json], count: -> { rows(FavoriteGroup, FavoriteGroup.ids) }},
    # A stranger's groups: the viewer's own carry their whole list, which they
    # wrote (PostIdList#serializable_hash).
    favorite_groups_arrays: { path: -> { ["/favorite_groups", {}] }, formats: %i[json], count: -> { widest_array("post_ids", @favgroups.map(&:id)) }},
    user_favorite_groups: { path: -> { ["/users/#{@member.id}/favorite_groups", {}] }, formats: %i[html json], count: -> { rows(FavoriteGroup, @favgroups.map(&:id)) }},
    favorite_group: { path: -> { ["/favorite_groups/#{@favgroups.first.id}", {}] }, formats: %i[html json], count: :pool_posts },
    favorites: { path: -> { ["/favorites", { search: { user_id: @member.id }}] }, formats: %i[json], count: -> { rows(Favorite, @favorites.map(&:id)) }},
    # The hover lists on a post's favorite count and score: lists of users.
    favorites_tooltip: { path: -> { ["/posts/#{@posts.first.id}/favorites", { variant: "tooltip" }] }, formats: %i[html], count: -> { @doc.css(".post-favoriter").size }, kind: :whole },
    post_votes: { path: -> { ["/post_votes", {}] }, formats: %i[html json], count: -> { rows(PostVote, PostVote.ids) }},
    post_votes_tooltip: { path: -> { ["/post_votes", { search: { post_id: @posts.first.id }, variant: "tooltip" }] }, formats: %i[html], count: -> { @doc.css(".post-voter").size }, kind: :whole },
    artist_commentaries: { path: -> { ["/artist_commentaries", {}] }, formats: %i[html json], count: -> { rows(ArtistCommentary, @commentaries.map(&:id)) }},
    artist_commentary_versions: { path: -> { ["/artist_commentary_versions", {}] }, formats: %i[html json], count: -> { rows(ArtistCommentaryVersion, ArtistCommentaryVersion.where(post_id: @commentaries.map(&:post_id)).ids) }},
    post_versions: { path: -> { ["/post_versions", { search: { post_id: @posts.map(&:id).join(",") }}] }, formats: %i[html json], count: -> { rows(PostVersion, PostVersion.where(post_id: @posts.map(&:id)).ids) }},
    post_events: { path: -> { ["/post_events", {}] }, formats: %i[html json], count: :post_events },
    post_replacements: { path: -> { ["/post_replacements", {}] }, formats: %i[html json], count: -> { rows(PostReplacement, @replacements.map(&:id)) }},
    post_appeals: { path: -> { ["/post_appeals", {}] }, formats: %i[html json], count: -> { rows(PostAppeal, @appeals.map(&:id)) }},
    post_flags: { path: -> { ["/post_flags", {}] }, formats: %i[html json], count: -> { rows(PostFlag, @flags.map(&:id)) }},
    post_approvals: { path: -> { ["/post_approvals", {}] }, formats: %i[html json], count: -> { rows(PostApproval, @approvals.map(&:id)) }},
    post_disapprovals: { path: -> { ["/post_disapprovals", {}] }, formats: %i[html json], count: -> { rows(PostDisapproval, @disapprovals.map(&:id)) }},
    reactions: { path: -> { ["/reactions", {}] }, formats: %i[json xml], count: -> { rows(Reaction, @reactions.map(&:id)) }},
    dtext_links: { path: -> { ["/dtext_links", {}] }, formats: %i[html json], count: -> { rows(DtextLink, DtextLink.ids) }},
    mod_actions: { path: -> { ["/mod_actions", {}] }, formats: %i[html json], count: -> { rows(ModAction, ModAction.ids) }},
    pool_versions: { path: -> { ["/pool_versions", {}] }, formats: %i[html json], count: -> { rows(PoolVersion, PoolVersion.ids) }},
    pool_versions_arrays: { path: -> { ["/pool_versions", {}] }, formats: %i[json], count: -> { widest_array("post_ids", PoolVersion.ids) }},
    # The HTML diff cell links every id a version added or removed: the same
    # arrays as the JSON, so the same first page.
    pool_versions_diff: { path: -> { ["/pool_versions", {}] }, formats: %i[html], count: -> { (linked_ids("posts") & @posts.map(&:id)).size }, kind: :whole },
    iqdb: { path: -> { ["/iqdb_queries", { hash: "abc" }] }, formats: %i[json], count: -> { @json.count { |match| @posts.map(&:id).include?(match.dig("post", "id")) } }, kind: :unpaged },
    recommended: { path: -> { ["/recommended_posts", {}] }, formats: %i[json], count: -> { @json.count { |rec| @posts.map(&:id).include?(rec.dig("post", "id")) } }, kind: :unpaged },
    children_include: { path: -> { ["/posts/#{@parent.id}", { only: "id,children[id]" }] }, formats: %i[json], count: -> { (@json["children"] || []).count { |c| @children.map(&:id).include?(c["id"]) } }, kind: :whole },
    children_include_list: { path: -> { ["/posts", { tags: "id:#{@parent.id}", only: "id,children[id]" }] }, formats: %i[json], count: -> { @json.sum { |p| (p["children"] || []).count { |c| @children.map(&:id).include?(c["id"]) } } }, kind: :whole },
    family_gallery: { path: -> { ["/posts/#{@parent.id}", { preset: "historical" }] }, formats: %i[html], count: -> { (html_post_ids & @children.map(&:id)).size }, kind: :whole },
    # The tags a search's sidebar lists: a wildcard drew 100 of them.
    sidebar_tags: { path: -> { ["/posts", { tags: "tierfix_*", preset: "historical" }] }, formats: %i[html], count: -> { (@doc.css("#tag-box [data-tag-name]").pluck("data-tag-name").uniq & @tags.map(&:name)).size }, kind: :whole },
    # A tag's wiki drawn above its search: its embeds, as a full account sees
    # them and at most the viewer's page of them (DText#format_text).
    tag_wiki_embeds: { path: -> { ["/posts", { tags: "tierfix_tag", preset: "historical" }] }, formats: %i[html], count: :embeds, kind: :whole },
    dtext_preview_requests: { verb: :post, path: -> { ["/dtext_preview", { body: @aliases.map { |a| "[ta:#{a.id}]" }.join("\n\n") }] }, formats: %i[html], count: -> { (wiki_links & @aliases.map(&:antecedent_name)).size }, kind: :whole },
    dtext_preview: { verb: :post, path: -> { ["/dtext_preview", { body: @posts.map { |p| "!post ##{p.id}" }.join("\n\n"), media_embeds: "1" }] }, formats: %i[html], count: :embeds, kind: :whole },
    # The hero band's posts are the belt's pool items (landing/_pool_item), the minibands' are cards; a post on both counts once.
    creator_gallery: { path: -> { ["/creators/#{@gallery.slug}", {}] }, formats: %i[html], count: -> { (@doc.css(".modcreator .modland-poolitem[data-id]").map { |item| item["data-id"].to_i } + @doc.css("a.modcreator-card[href]").map { |a| a["href"][%r{\A/posts/(\d+)\z}, 1].to_i }).uniq.count { |id| @posts.map(&:id).include?(id) } }, kind: :whole },
    show_seq: { path: -> { ["/posts/#{@posts[2].id}/show_seq", { seq: "next", q: "tierfix_tag" }] }, formats: %i[html], kind: :walk, expect: 410, walked: -> { response.redirect? }},
    historical_navbar: { path: -> { ["/posts/#{@posts[2].id}", { preset: "historical", q: "pool:#{@pools.first.id}" }] }, formats: %i[html], kind: :walk, expect: :drawn, walked: -> { response.successful? && @doc.css(".search-navbar a, .pool-navbar a[rel~=next], .pool-navbar a[rel~=prev]").any? }},
    # The order editor draws the group's posts: the creator's own, so only a
    # Restricted creator is capped here (a signed-out viewer owns none).
    favorite_group_order: { path: -> { ["/favorite_groups/#{@own_groups.fetch(@viewer_user.id).id}/order/edit", {}] }, formats: %i[html], count: -> { (@doc.css("#sortable li[id]").filter_map { |li| li["id"][/_(\d+)\z/, 1]&.to_i } & @posts.map(&:id)).size }, kind: :whole, viewers: %i[restricted] },
    # A user's roster with counts, sized by group_limit.
    reports: { path: -> { ["/reports/posts", { search: { group: "uploader", group_limit: 1000 }}] }, formats: %i[json], count: -> { @json.count { |row| @uploader_names.include?(row["uploader"]) } }, kind: :whole },

    # --- lists of everything else ---
    tags: { path: -> { ["/tags", { search: { name_matches: "tierfix_*" }}] }, formats: %i[html json xml], count: -> { rows(Tag, Tag.where("name LIKE 'tierfix%'").ids) }},
    # A nested has-many of anything is a list: each row carried it whole.
    tags_nested: { path: -> { ["/tags", { search: { name: "tierfix_tag" }, only: "name,consequent_aliases[antecedent_name]" }] }, formats: %i[json], count: -> { @json.sum { |t| (t["consequent_aliases"] || []).count { |a| @aliases_to_tag.map(&:antecedent_name).include?(a["antecedent_name"]) } } }, kind: :whole },
    wiki_nested_embeds: { path: -> { ["/wiki_pages", { search: { title: "tierfix_tag" }, only: "title,dtext_links[id,embedded_post[id]]" }] }, formats: %i[json], count: -> { @json.sum { |w| (w["dtext_links"] || []).count { |l| DtextLink.where(model: @tag_wiki).ids.include?(l["id"]) } } }, kind: :whole },
    legacy_tags: { path: -> { ["/tag/index", { search: { name_matches: "tierfix_*" }}] }, formats: %i[json xml], count: -> { rows(Tag, Tag.where("name LIKE 'tierfix%'").ids) }},
    users: { path: -> { ["/users", { search: { name_matches: "tierfix_u*" }}] }, formats: %i[html json], count: -> { rows(User, @users.map(&:id)) }},
    wiki_pages: { path: -> { ["/wiki_pages", { search: { title_normalize: "tierfix_w*" }}] }, formats: %i[html json], count: -> { rows(WikiPage, @wikis.map(&:id)) }},
    wiki_page_versions: { path: -> { ["/wiki_page_versions", {}] }, formats: %i[html json], count: -> { rows(WikiPageVersion, WikiPageVersion.ids) }},
    # A tag's wiki page: the tags aliased to it, the tags implicating it, and
    # the Recent Changes sidebar every wiki page draws.
    wiki_aliases: { path: -> { ["/wiki_pages/tierfix_tag", {}] }, formats: %i[html], count: -> { (wiki_links & @aliases_to_tag.map(&:antecedent_name)).size }, kind: :whole },
    wiki_implications: { path: -> { ["/wiki_pages/tierfix_tag", {}] }, formats: %i[html], count: -> { (wiki_links & @implications_to_tag.map(&:antecedent_name)).size }, kind: :whole },
    wiki_recent_changes: { path: -> { ["/wiki_pages/tierfix_tag", {}] }, formats: %i[html], count: -> { (@doc.xpath("//section[h2[contains(., 'Recent Changes')]]//a/@href").map { |href| CGI.unescape(href.value.delete_prefix("/wiki_pages/")) } & WikiPage.pluck(:title)).size }, kind: :whole },
    wiki_version_embeds: { path: -> { ["/wiki_page_versions/#{@tag_wiki.versions.last.id}", {}] }, formats: %i[html], count: :embeds, kind: :whole },
    artists: { path: -> { ["/artists", {}] }, formats: %i[html json], count: -> { rows(Artist, @artists.map(&:id)) }},
    artist_wiki_embeds: { path: -> { ["/artists/#{@artists.first.id}", {}] }, formats: %i[html], count: :embeds, kind: :whole },
    artist_versions: { path: -> { ["/artist_versions", {}] }, formats: %i[html json], count: -> { rows(ArtistVersion, ArtistVersion.where(artist_id: @artists.map(&:id)).ids) }},
    artist_urls: { path: -> { ["/artist_urls", {}] }, formats: %i[html json], count: -> { rows(ArtistURL, ArtistURL.where(artist_id: @artists.map(&:id)).ids) }},
    tag_aliases: { path: -> { ["/tag_aliases", {}] }, formats: %i[html json], count: -> { rows(TagAlias, TagAlias.ids) }},
    tag_implications: { path: -> { ["/tag_implications", {}] }, formats: %i[html json], count: -> { rows(TagImplication, TagImplication.ids) }},
    tag_versions: { path: -> { ["/tag_versions", {}] }, formats: %i[html json], count: -> { rows(TagVersion, @tag_versions.map(&:id)) }},
    bulk_update_requests: { path: -> { ["/bulk_update_requests", {}] }, formats: %i[html json], count: -> { rows(BulkUpdateRequest, @burs.map(&:id)) }},
    bans: { path: -> { ["/bans", {}] }, formats: %i[html json], count: -> { rows(Ban, @bans.map(&:id)) }},
    user_feedbacks: { path: -> { ["/user_feedbacks", {}] }, formats: %i[html json], count: -> { rows(UserFeedback, @feedbacks.map(&:id)) }},
    user_name_change_requests: { path: -> { ["/user_name_change_requests", {}] }, formats: %i[html json], count: -> { rows(UserNameChangeRequest, @name_changes.map(&:id)) }, viewers: %i[restricted] },
    dmails: { path: -> { ["/dmails", {}] }, formats: %i[html json], count: -> { rows(Dmail, @dmails.map(&:id)) }, viewers: %i[restricted] },
    saved_searches: { path: -> { ["/saved_searches", {}] }, formats: %i[html json], count: -> { rows(SavedSearch, @saved_searches.map(&:id)) }, viewers: %i[restricted] },
    creator_galleries: { path: -> { ["/creators", {}] }, formats: %i[html], count: -> { @doc.css(".modcreator-index-list a").count { |a| @galleries.map { |g| "/creators/#{g.slug}" }.include?(a["href"]) } }, kind: :whole },
    autocomplete: { path: -> { ["/autocomplete", { search: { query: "tierfix_", type: "tag_query" }}] }, formats: %i[json], count: -> { @json.count { |r| @tags.map(&:name).include?(r["value"]) } }, kind: :unpaged },
    related_tags: { path: -> { ["/related_tag", { query: "tierfix_tag" }] }, formats: %i[json], count: -> { (@json["related_tags"] || []).count { |r| @tags.map(&:name).include?(r.dig("tag", "name")) } }, kind: :unpaged },
    related_tags_wiki: { path: -> { ["/related_tag", { query: "tierfix_tag" }] }, formats: %i[json], count: -> { (@json["wiki_page_tags"] || []).count { |t| @tags.map(&:name).include?(t["name"]) } }, kind: :unpaged },
  }.freeze

  # Every GET route, classified (ACCOUNT_LIMITS.md 5.1). A list of anything
  # is a SURFACES row; everything else says what it is and why.
  ROUTES = {
    "admin/artist_claims#index" => [:staff_or_owner, "admins only (ArtistClaimPolicy#index?)"],
    "admin/landing_settings#show" => [:staff_or_owner, "the landing console, admins only"],
    "admin/signup_tokens#index" => [:staff_or_owner, "admins only"],
    "admin/users#edit" => [:staff_or_owner, "admins only"],
    "ai_tags#index" => [:retired],
    "api_keys#edit" => [:staff_or_owner, "the viewer's own key"],
    "api_keys#index" => [:staff_or_owner, "the viewer's own keys"],
    "api_keys#new" => [:not_a_list, "a form"],
    "artist_commentaries#index" => :artist_commentaries,
    "artist_commentaries#show" => [:single_record],
    "artist_commentary_versions#index" => :artist_commentary_versions,
    "artist_commentary_versions#show" => [:single_record],
    "artist_urls#index" => :artist_urls,
    "artist_versions#index" => :artist_versions,
    "artist_versions#show" => [:single_record],
    "artists#edit" => [:not_a_list, "a form"],
    "artists#index" => :artists,
    "artists#new" => [:not_a_list, "a form"],
    "artists#show" => :artist_wiki_embeds,
    "artists#show_or_new" => [:single_record],
    "autocomplete#index" => :autocomplete,
    "backup_codes#confirm_recover" => [:staff_or_owner, "the viewer's own codes"],
    "backup_codes#index" => [:staff_or_owner, "the viewer's own codes"],
    "bans#edit" => [:staff_or_owner, "moderators only"],
    "bans#index" => :bans,
    "bans#new" => [:staff_or_owner, "moderators only"],
    "bans#show" => [:single_record],
    "bulk_update_requests#edit" => [:not_a_list, "a form"],
    "bulk_update_requests#index" => :bulk_update_requests,
    "bulk_update_requests#new" => [:not_a_list, "a form"],
    "bulk_update_requests#show" => [:single_record],
    "comment_votes#index" => [:retired],
    "comment_votes#show" => [:retired],
    "comments#edit" => [:retired],
    "comments#index" => [:retired],
    "comments#new" => [:retired],
    "comments#show" => [:retired],
    "counts#index" => [:not_a_list, "no such action: Rails' implicit render finds only application/index.sitemap, and every other format answers 406"],
    "counts#posts" => [:not_a_list, "one number"],
    "creator_galleries#edit" => [:staff_or_owner, "the page's owner or an admin"],
    "creator_galleries#index" => :creator_galleries,
    "creator_galleries#new" => [:not_a_list, "a form"],
    "creator_galleries#show" => :creator_gallery,
    "creator_prefixes#index" => [:not_a_list, "the creator prefix registry: a few config entries, not records"],
    "creator_prefixes#releases" => [:staff_or_owner, "admins only"],
    "dmails#index" => :dmails,
    "dmails#new" => [:not_a_list, "a form"],
    "dmails#show" => [:single_record],
    "dmcas#show" => [:not_a_list, "a form"],
    "dmcas#template" => [:not_a_list, "a form"],
    "dtext_links#index" => :dtext_links,
    "emails#edit" => [:staff_or_owner, "the viewer's own address"],
    "emails#index" => [:staff_or_owner, "moderators only (EmailAddressPolicy#index?)"],
    "emails#show" => [:staff_or_owner, "the viewer's own address"],
    "emails#verify" => [:staff_or_owner, "the viewer's own address"],
    "errors#show" => [:not_a_list, "the error page's one picture (ACCOUNT_LIMITS.md row 14)"],
    "explore/posts#popular" => :explore_popular,
    "favorite_group_orders#edit" => :favorite_group_order,
    "favorite_groups#edit" => [:staff_or_owner, "the group's creator"],
    "favorite_groups#index" => %i[favorite_groups favorite_groups_arrays user_favorite_groups],
    "favorite_groups#new" => [:not_a_list, "a form"],
    "favorite_groups#show" => :favorite_group,
    "favorites#index" => %i[favorites favorites_tooltip],
    "forum_post_votes#index" => [:retired],
    "forum_post_votes#show" => [:retired],
    "forum_posts#edit" => [:retired],
    "forum_posts#index" => [:retired],
    "forum_posts#new" => [:retired],
    "forum_posts#search" => [:retired],
    "forum_posts#show" => [:retired],
    "forum_topic_visits#index" => [:retired],
    "forum_topics#edit" => [:retired],
    "forum_topics#index" => [:retired],
    "forum_topics#new" => [:retired],
    "forum_topics#show" => [:retired],
    "fourier_generation_metadata#raw" => [:staff_or_owner, "builders only"],
    "fourier_generation_metadata#show" => [:single_record],
    "fourier_identity#show" => [:not_a_list, "who the viewer is"],
    "fourier_jail#index" => [:staff_or_owner, "named accounts only"],
    "fourier_tag_sources#show" => [:single_record],
    "health#postgres" => [:not_a_list, "a health check"],
    "health#redis" => [:not_a_list, "a health check"],
    "health#show" => [:not_a_list, "a health check"],
    "ip_addresses#show" => [:staff_or_owner, "moderators only"],
    "ip_bans#index" => [:staff_or_owner, "moderators only"],
    "ip_bans#new" => [:staff_or_owner, "moderators only"],
    "ip_bans#show" => [:staff_or_owner, "moderators only"],
    "ip_geolocations#index" => [:staff_or_owner, "moderators only"],
    "iqdb_queries#index" => [:not_a_list, "no such action (/posts/:id/similar's target): Rails' implicit render finds only application/index.sitemap, and every other format answers 406"],
    "iqdb_queries#show" => :iqdb,
    "jobs#index" => [:retired],
    "landing#show" => [:exempt, :hero_band],
    "landing#slides" => [:exempt, :hero_band],
    "legacy#posts" => :legacy_posts,
    "legacy#tags" => :legacy_tags,
    "maintenance/user/count_fixes#new" => [:not_a_list, "a form"],
    "maintenance/user/email_notifications#show" => [:not_a_list, "a form"],
    "media_assets#image" => [:retired],
    "media_assets#index" => [:retired],
    "media_assets#show" => [:retired],
    "media_metadata#index" => [:retired],
    "metrics#index" => [:retired],
    "metrics#instance" => [:retired],
    "metrics#statistics" => [:retired],
    "mock_services#autotagger_evaluate" => [:not_a_list, "a stand-in for an upstream service, for development"],
    "mock_services#iqdb_query" => [:not_a_list, "a stand-in for an upstream service, for development"],
    "mock_services#recommender_recommend" => [:not_a_list, "a stand-in for an upstream service, for development"],
    "mock_services#recommender_similar" => [:not_a_list, "a stand-in for an upstream service, for development"],
    "mock_services#reportbooru_post_searches" => [:not_a_list, "a stand-in for an upstream service, for development"],
    "mod_actions#index" => :mod_actions,
    "mod_actions#show" => [:single_record],
    "moderation_reports#index" => [:staff_or_owner, "moderators only (ModerationReport.visible)"],
    "moderation_reports#new" => [:not_a_list, "a form"],
    "moderation_reports#show" => [:staff_or_owner, "moderators only"],
    "moderator/post/posts#confirm_move_favorites" => [:staff_or_owner, "moderators only"],
    "moderator_dashboard#show" => [:staff_or_owner, "moderators only"],
    "modqueue#index" => [:staff_or_owner, "approvers only"],
    "modulation#creator_activity" => [:not_a_list, "a yes or no per name, at most CreatorActivity::MAX_NAMES"],
    "modulation#show" => [:single_record, "one post's payload; its neighbours are the walk gate's"],
    "modulation_session#status" => [:not_a_list, "the viewer's own session"],
    "news_updates#edit" => [:staff_or_owner, "admins only"],
    "news_updates#index" => [:staff_or_owner, "admins only (NewsUpdatePolicy#index?)"],
    "news_updates#new" => [:staff_or_owner, "admins only"],
    "news_updates#show" => [:staff_or_owner, "admins only"],
    "note_versions#index" => [:retired],
    "note_versions#show" => [:retired],
    "notes#index" => [:retired],
    "notes#preview" => [:retired],
    "notes#show" => [:retired],
    "password_resets#edit" => [:not_a_list, "a form"],
    "password_resets#show" => [:not_a_list, "a form"],
    "passwords#edit" => [:not_a_list, "a form"],
    "pool_orders#edit" => [:staff_or_owner, "an editor's form: PoolPolicy#update? refuses Restricted and signed out"],
    "pool_versions#diff" => [:single_record, "one version against another"],
    "pool_versions#index" => %i[pool_versions pool_versions_arrays pool_versions_diff],
    "pool_versions#search" => [:not_a_list, "a search form"],
    "pools#edit" => [:staff_or_owner, "an editor's form: PoolPolicy#update? refuses Restricted and signed out"],
    "pools#gallery" => :pools_gallery,
    "pools#index" => %i[pools pools_arrays],
    "pools#new" => [:not_a_list, "a form"],
    "pools#show" => :pool,
    "post_appeals#edit" => [:staff_or_owner, "the appeal's creator"],
    "post_appeals#index" => :post_appeals,
    "post_appeals#new" => [:not_a_list, "a form"],
    "post_appeals#show" => [:single_record],
    "post_approvals#index" => :post_approvals,
    "post_approvals#show" => [:single_record],
    "post_disapprovals#edit" => [:staff_or_owner, "approvers only"],
    "post_disapprovals#index" => :post_disapprovals,
    "post_disapprovals#show" => [:single_record],
    "post_events#index" => :post_events,
    "post_flags#edit" => [:staff_or_owner, "the flag's creator"],
    "post_flags#index" => :post_flags,
    "post_flags#new" => [:not_a_list, "a form"],
    "post_flags#show" => [:single_record],
    "post_replacements#index" => :post_replacements,
    "post_replacements#new" => [:staff_or_owner, "approvers only"],
    "post_replacements#show" => [:single_record],
    "post_versions#index" => :post_versions,
    "post_versions#search" => [:not_a_list, "a search form"],
    "post_votes#index" => %i[post_votes post_votes_tooltip],
    "post_votes#show" => [:single_record],
    "posts#index" => %i[posts sidebar_tags tag_wiki_embeds children_include_list],
    "posts#random" => [:single_record, "one post a request; no reach cap until measured (operator, 2026-10-18)"],
    "posts#show" => %i[children_include family_gallery historical_navbar],
    "posts#show_seq" => :show_seq,
    "rate_limits#index" => [:staff_or_owner, "the viewer's own limits (RateLimit.visible)"],
    "reactions#index" => :reactions,
    "reactions#show" => [:single_record],
    "recommended_posts#index" => :recommended,
    "related_tags#show" => %i[related_tags related_tags_wiki],
    "reports#index" => [:not_a_list, "the list of reports, a fixed menu"],
    "reports#show" => :reports,
    "robots#index" => [:not_a_list, "robots.txt"],
    "saved_searches#edit" => [:staff_or_owner, "the search's owner"],
    "saved_searches#index" => :saved_searches,
    "sessions#confirm_password" => [:not_a_list, "a form"],
    "sessions#done" => [:not_a_list, "a form"],
    "sessions#logout" => [:not_a_list, "a form"],
    "sessions#new" => [:not_a_list, "a form"],
    "site_credentials#index" => [:staff_or_owner, "admins only"],
    "site_credentials#new" => [:staff_or_owner, "admins only"],
    "site_credentials#show" => [:staff_or_owner, "admins only"],
    "sources#show" => [:single_record, "one source; its related-posts strip is a fixed 5"],
    "static#2257" => [:not_a_list, "a static page"],
    "static#bookmarklet" => [:not_a_list, "a static page"],
    "static#colors" => [:not_a_list, "a static page"],
    "static#components" => [:not_a_list, "a static page"],
    "static#contact" => [:not_a_list, "a static page"],
    "static#dtext_help" => [:not_a_list, "a static page"],
    "static#keyboard_shortcuts" => [:not_a_list, "a static page"],
    "static#not_found" => [:not_a_list, "a static page"],
    "static#opensearch" => [:not_a_list, "a static page"],
    "static#site_map" => [:not_a_list, "a static page"],
    "static#sitemap_index" => [:not_a_list, "id ranges for crawlers, not records (ACCOUNT_LIMITS.md row 21)"],
    "static#terms_of_service" => [:not_a_list, "a static page"],
    "status#show" => [:staff_or_owner, "status_min_level and above"],
    "tag_aliases#index" => :tag_aliases,
    "tag_aliases#show" => [:single_record],
    "tag_implications#index" => :tag_implications,
    "tag_implications#show" => [:single_record],
    "tag_versions#index" => :tag_versions,
    "tag_versions#show" => [:single_record],
    "tags#edit" => [:not_a_list, "a form"],
    "tags#index" => %i[tags tags_nested],
    "tags#show" => [:single_record],
    "totp#edit" => [:not_a_list, "a form"],
    "upgrade_codes#index" => [:staff_or_owner, "the viewer's own codes (UpgradeCode.visible)"],
    "upgrade_codes#redeem" => [:not_a_list, "a form"],
    "upload_media_assets#index" => [:staff_or_owner, "the viewer's own uploads"],
    "upload_media_assets#show" => [:staff_or_owner, "the viewer's own upload"],
    "uploads#index" => [:staff_or_owner, "the viewer's own uploads"],
    "uploads#new" => [:not_a_list, "a form"],
    "uploads#show" => [:staff_or_owner, "the viewer's own upload"],
    "user_actions#index" => [:staff_or_owner, "moderators only (UserActionPolicy)"],
    "user_actions#show" => [:staff_or_owner, "moderators only (UserActionPolicy)"],
    "user_events#index" => [:staff_or_owner, "the viewer's own events (UserEvent.visible)"],
    "user_feedbacks#edit" => [:staff_or_owner, "the feedback's creator"],
    "user_feedbacks#index" => :user_feedbacks,
    "user_feedbacks#new" => [:staff_or_owner, "builders and above"],
    "user_feedbacks#show" => [:single_record],
    "user_name_change_requests#index" => :user_name_change_requests,
    "user_name_change_requests#new" => [:not_a_list, "a form"],
    "user_name_change_requests#show" => [:single_record],
    "user_upgrades#index" => [:staff_or_owner, "the viewer's own upgrades"],
    "user_upgrades#new" => [:not_a_list, "a form"],
    "user_upgrades#payment" => [:staff_or_owner, "the viewer's own upgrade"],
    "user_upgrades#receipt" => [:staff_or_owner, "the viewer's own upgrade"],
    "user_upgrades#show" => [:staff_or_owner, "the viewer's own upgrade"],
    "users#custom_style" => [:not_a_list, "the viewer's own stylesheet"],
    "users#deactivate" => [:not_a_list, "a form"],
    "users#demote" => [:staff_or_owner, "moderators only"],
    "users#edit" => [:not_a_list, "a form"],
    "users#index" => :users,
    "users#new" => [:not_a_list, "a form"],
    "users#profile" => [:single_record, "the viewer's own profile; its strips (6/6/10) are under the cap"],
    "users#promote" => [:staff_or_owner, "moderators only"],
    "users#settings" => [:not_a_list, "a form"],
    "users#show" => [:single_record, "one profile; its strips (6/6/10) are under the cap"],
    "webhooks#index" => [:staff_or_owner, "admins only"],
    "wiki_page_versions#diff" => [:single_record, "one version against another"],
    "wiki_page_versions#index" => :wiki_page_versions,
    "wiki_page_versions#show" => :wiki_version_embeds,
    "wiki_pages#edit" => [:not_a_list, "a form"],
    "wiki_pages#index" => %i[wiki_pages wiki_nested_embeds],
    "wiki_pages#new" => [:not_a_list, "a form"],
    "wiki_pages#show" => %i[wiki_aliases wiki_implications wiki_recent_changes],
    "wiki_pages#show_or_new" => [:single_record],
  }.freeze
  # The GoodJob dashboard, mounted at /good_job: admins only, every page.
  ENGINE_ROUTES = { "good_job/" => [:staff_or_owner, "the GoodJob dashboard, admins only"] }.freeze
  CLASSES = %i[single_record not_a_list exempt retired staff_or_owner].freeze
  # The files allowed a fixed list size above the tier's page, and why.
  FIXED_SIZES = {
    "app/controllers/legacy_controller.rb" => "the relation is paginated on the same line, which clamps it",
    "app/controllers/admin/artist_claims_controller.rb" => "admins only",
  }.freeze

  # --- extractors ---------------------------------------------------------

  # Post ids drawn as post previews (historical) or gallery cards (Modulation).
  def html_post_ids
    previews = @doc.css("article.post-preview[data-id]").map { |node| node["data-id"].to_i }
    cards = @doc.css("a.modgal-card[href]").filter_map { |node| node["href"][%r{\A/posts/(\d+)}, 1]&.to_i }
    (previews + cards).uniq
  end

  # The distinct ids an HTML body links to as /<path>/<id>: a pool gallery's
  # covers link their pool; an event table links each event's post.
  def linked_ids(path)
    @doc.css("a[href]").filter_map { |node| node["href"][%r{\A/#{path}/(\d+)\z}, 1]&.to_i }.uniq
  end

  # How many of `ids` the body lists as records of `model`: JSON objects by
  # id; HTML table rows by their TableBuilder id (`<model>-<id>`). The test
  # database holds only what build_fixtures made, so `Model.ids` is the
  # fixtures of a list whose newest page another fixture fills.
  def rows(model, ids)
    if @json
      list = @json.is_a?(Array) ? @json : []
      list.count { |record| record.is_a?(Hash) && ids.include?(record["id"]) }
    else
      prefix = model.model_name.singular.dasherize
      @doc.css("[id^='#{prefix}-']").filter_map { |node| node["id"][/\A#{prefix}-(\d+)\z/, 1]&.to_i }.uniq.count { |id| ids.include?(id) }
    end
  end

  # The longest array of fixture post ids any one of `records` (ids) carries.
  def widest_array(key, records)
    fixture = @posts.map(&:id)
    @json.select { |record| records.include?(record["id"]) }.map { |record| (record[key] || []).count { |id| fixture.include?(id) } }.max.to_i
  end

  # The wiki titles an HTML body links to.
  def wiki_links
    @doc.css("a[href^='/wiki_pages/']").filter_map { |node| node["href"][%r{\A/wiki_pages/([^/?#]+)\z}, 1] }.map { |title| CGI.unescape(title) }.uniq
  end

  def count_for(row)
    case row[:count]
    when :posts then @json ? @json.count { |p| p.is_a?(Hash) && @posts.map(&:id).include?(p["id"]) } : (html_post_ids & @posts.map(&:id)).size
    when :pool_posts then @json ? (@json["post_ids"] & @posts.map(&:id)).size : (html_post_ids & @posts.map(&:id)).size
    # One table row an event: two events can be about one post.
    when :post_events then @json ? @json.count { |e| e.is_a?(Hash) && Post.exists?(e["post_id"]) } : @doc.css("tbody tr").count { |tr| tr.css("a[href]").any? { |a| a["href"].match?(%r{\A/posts/\d+\z}) } }
    # DText media embeds drawn as pictures, of fixture posts.
    when :embeds then @doc.css("article.dtext-media-embed[data-id]").count { |node| node.at_css(".media-embed-image img") && @posts.map(&:id).include?(node["data-id"].to_i) }
    else instance_exec(&row[:count])
    end
  end

  # --- requests -----------------------------------------------------------

  def url(row, format, params = {})
    path, base = instance_exec(&row[:path])
    path = "#{path}.#{format}" unless format == :html
    [path, base.merge(params)]
  end

  def become(viewer)
    @headers = {}
    @viewer_user = { member: @member, restricted: @restricted }.fetch(viewer, User.anonymous)
    case viewer
    when :member then login_as(@member)
    when :restricted then login_as(@restricted)
    when :signed_out
      delete session_path
    when :matrix
      delete session_path
      @headers = { "X-Fourier-Identity" => MXID }
    end
  end

  # Ask, and parse what came back for the extractor. Each request runs in a
  # savepoint that is rolled back after it, so one that fails in SQL (a 500)
  # is a line in the report rather than an aborted transaction that takes
  # every later request down with it.
  def ask(row, format, params = {})
    path, query = url(row, format, params)
    connection = ActiveRecord::Base.connection
    connection.create_savepoint("tier_probe")
    begin
      if row[:verb] == :post
        post path, params: query, headers: @headers
      else
        get path, params: query, headers: @headers
      end
    rescue StandardError => e
      @json = @doc = nil
      return "raised #{e.class} (#{e.message.lines.first.to_s.strip.truncate(100)})"
    ensure
      connection.rollback_to_savepoint("tier_probe")
      connection.release_savepoint("tier_probe")
    end
    @json = (format == :json && response.media_type == "application/json") ? response.parsed_body : nil
    @doc = (format == :html) ? Nokogiri::HTML5(response.body) : nil
    response.status
  end

  def counted_formats(row)
    row[:formats] & %i[html json]
  end

  # The table walk itself: every row, as each capped viewer, with each probe.
  # Returns a list of what failed, one line each, so a red run is the table
  # of rows that leak rather than the first of them.
  def walk(names, viewers = %i[restricted signed_out matrix])
    failures = []
    become(:member)
    names.each do |name|
      row = SURFACES.fetch(name)
      # The positive control: a full account sees more than the cap, or the
      # extractor is blind and the clamp below would pass vacuously.
      if row[:kind] == :walk
        status = ask(row, :html)
        if !status.is_a?(Integer)
          failures << "#{name}: control: the request raised (#{status})"
        elsif !instance_exec(&row[:walked])
          failures << "#{name}: control: a full account must walk (got #{status})"
        end
      else
        counted_formats(row).each do |format|
          status = ask(row, format, limit: 1000)
          seen = (status == 200) ? count_for(row) : nil
          failures << "#{name}.#{format}: control: a full account must see more than #{CAP} fixtures (status #{status}, saw #{seen.inspect})" unless seen.to_i > CAP
        end
      end
    end

    viewers.each do |viewer|
      become(viewer)
      names.each do |name|
        row = SURFACES.fetch(name)
        next if row[:viewers]&.exclude?(viewer)

        failures.concat(probe(name, row, viewer))
      end
    end
    failures
  end

  def probe(name, row, viewer)
    failures = []
    kind = row[:kind] || :listing
    if kind == :walk
      status = ask(row, :html)
      # A crash is not a refusal, and a page that vanished is not one either:
      # each walk says which answer it gives.
      if !status.is_a?(Integer)
        failures << "#{name} as #{viewer}: the request raised (#{status})"
      elsif row[:expect] == 410
        failures << "#{name} as #{viewer}: expected the tier's 410, got #{status}" unless status == 410
      elsif status != 200 || instance_exec(&row[:walked])
        failures << "#{name} as #{viewer}: expected a 200 page with no neighbour links, got #{status}#{" with links" if status == 200}"
      end
      return failures
    end

    if kind == :listing
      row[:formats].each do |format|
        CURSOR_PROBES.each do |label, params|
          status = ask(row, format, params)
          failures << "#{name}.#{format} as #{viewer} #{label}: expected 410, got #{status}" unless status == 410
        end
      end
      if row[:window]
        cursor = @posts.max_by(&:id).id.to_s
        { "anchor" => { anchor: cursor }, "before" => { before: cursor }}.each do |label, params|
          status = ask(row, :html, params.merge(preset: "modulation"))
          failures << "#{name}.html as #{viewer} #{label}=<cursor>: expected 410, got #{status}" unless status == 410
        end
      end
    end

    counted_formats(row).each do |format|
      status = ask(row, format, (kind == :whole) ? {} : { limit: 1000 })
      seen = count_for(row) if status == 200
      if status != 200 || seen > CAP
        failures << "#{name}.#{format} as #{viewer}: expected 200 with at most #{CAP}, got #{status} with #{seen.inspect}"
        next
      end
      # A capped viewer is drawn no page they would be refused.
      if format == :html && kind == :listing
        links = @doc.css(".paginator a[href*='page=']:not([hidden])")
        failures << "#{name}.html as #{viewer}: the paginator draws #{links.size} page links past the first" if links.any?
      end
      next if row[:blind]&.include?(viewer)

      if seen.zero?
        # 0 passes "at most CAP" without measuring anything: a clamp that
        # returns nothing, or an extractor blind to this viewer's markup.
        failures << "#{name}.#{format} as #{viewer}: saw none of the fixtures: the extractor or the surface is blind to this viewer (a row where they rightly see none says so in blind:)"
      elsif viewer == :restricted && seen != CAP
        failures << "#{name}.#{format} as #{viewer}: expected exactly #{CAP}, the account's page, saw #{seen}"
      end
    end
    failures
  end

  # --- fixtures -----------------------------------------------------------

  def build_fixtures
    @member = create(:user, name: "tiermember")
    @restricted = create(:restricted_user, name: "tierrestricted")
    @mod = create(:moderator_user)
    @approver = create(:approver_user)
    @admin = create(:admin_user)

    as(@member) do
      # Each post also carries a tag of its own, so a page can be searched for
      # the tags of a post it must not name (the creator gallery's cut).
      @posts = Array.new(N) { |i| create(:post, tag_string: "tierfix_tag tierfix_a tierfix_b tierfix_c tierfix_d tierfix_e tierfix_uniq#{i}", rating: "g") }
      @parent = create(:post, tag_string: "tierfix_parent", rating: "g")
      @children = create_list(:post, 4, parent: @parent, tag_string: "tierfix_child", rating: "g")
    end
    @tags = Tag.where(name: %w[tierfix_tag tierfix_a tierfix_b tierfix_c tierfix_d tierfix_e]).to_a

    as(@member) do
      @pools = Array.new(N) { |i| create(:pool, name: "tierfix_pool_#{i}", category: "series", post_ids: @posts.map(&:id)) }
      @favgroups = Array.new(N) { |i| create(:favorite_group, creator: @member, name: "tierfix_fg_#{i}", post_ids: @posts.map(&:id)) }
      @favorites = @posts.map { |p| create(:favorite, user: @member, post: p) }
      @votes = @posts.map { |p| create(:post_vote, user: create(:gold_user), post: p, score: 1) }
      @commentaries = Array.new(N) { create(:artist_commentary) }
      @wikis = Array.new(N) { |i| create(:wiki_page, title: "tierfix_w#{i}", body: "[[tierfix_link_#{i}]]") }
      @link_targets = Array.new(N) { |i| "tierfix_link_#{i}" }
      @artists = Array.new(N) { |i| create(:artist, name: "tierfix_ar#{i}", url_string: "https://tierfix#{i}.example.com/") }
      @burs = Array.new(N) { |i| create(:bulk_update_request, user: @member, script: "create alias tierfix_bur#{i} -> tierfix_burc#{i}") }
    end
    as(@admin) do
      @aliases = Array.new(N) { |i| create(:tag_alias, antecedent_name: "tierfix_al#{i}", consequent_name: "tierfix_alc#{i}") }
      @implications = Array.new(N) { |i| create(:tag_implication, antecedent_name: "tierfix_im#{i}", consequent_name: "tierfix_imc#{i}") }
      @tag_versions = @tags.first(N).map { |tag| create(:tag_version, tag: tag, name: tag.name) }
      @mod_actions = Array.new(N) { create(:mod_action, creator: @admin, subject: @posts.first) }
    end
    # Not processed: five replacements by one file would make the posts one
    # md5. The listing is what is measured, not the replacement.
    PostReplacementProcessor.any_instance.stubs(:process!)
    @replacements = Array.new(N) { as(@approver) { create(:post_replacement, creator: @approver) } }
    # One appeal a creator: an account has an appeal limit.
    @appeals = Array.new(N) { create(:user).then { |appealer| as(appealer) { create(:post_appeal, creator: appealer) } } }
    @flags = @posts.map { |p| as(@approver) { create(:post_flag, post: p, creator: @approver) } }
    @approvals = Array.new(N) { as(@mod) { create(:post_approval) } }
    @disapprovals = Array.new(N) { as(@approver) { create(:post_disapproval, user: @approver) } }
    # This booru configures no reactions (Danbooru.config.reactions is empty),
    # so the rows are written past the inclusion check: what is measured is
    # the listing, not the reaction.
    @reactions = @posts.map { |p| Reaction.new(model: p, creator: @member, reaction_id: 1).tap { |r| r.save!(validate: false) } }
    @users = Array.new(N) { |i| create(:user, name: "tierfix_u#{i}") }
    # More favoriters and voters on one post than CAP, for its hover lists.
    @users.each { |user| create(:favorite, user: user, post: @posts.first) }
    Array.new(N) { create(:post_vote, user: create(:gold_user), post: @posts.first, score: 1) }
    @uploader_names = @posts.map { |p| p.uploader.name }
    # A tag with more aliases and implications to it than CAP, and a wiki page
    # that links more tags and embeds more posts than CAP.
    as(@admin) do
      @aliases_to_tag = Array.new(N) { |i| create(:tag_alias, antecedent_name: "tierfix_alx#{i}", consequent_name: "tierfix_tag") }
      @implications_to_tag = Array.new(N) { |i| create(:tag_implication, antecedent_name: "tierfix_imx#{i}", consequent_name: "tierfix_tag") }
    end
    embeds = @posts.map { |p| "!post ##{p.id}" }.join("\n\n")
    as(@member) do
      @tag_wiki = create(:wiki_page, title: "tierfix_tag", body: "[[tierfix_a]] [[tierfix_b]] [[tierfix_c]] [[tierfix_d]] [[tierfix_e]]\n\n#{embeds}")
      create(:wiki_page, title: @artists.first.name, body: embeds)
    end
    # A pool history whose versions differ by more than CAP posts: the test
    # archive stores no added_post_ids, so the diff is version against version.
    @diff_pool = as(@member) { create(:pool, name: "tierfix_diff_pool", category: "series") }
    as(@admin) { @diff_pool.update!(post_ids: @posts.map(&:id)) }
    # The test archive numbers every version 1 (MockPoolSqsService); the real
    # one counts up, which is what a diff against the previous one reads.
    PoolVersion.where(pool_id: @diff_pool.id).order(:id).last.update!(version: 2)
    # A favorite group each signed-in viewer owns, for the order editor.
    @own_groups = { @member.id => @favgroups.first, @restricted.id => as(@restricted) { create(:favorite_group, creator: @restricted, name: "tierfix_fg_mine", post_ids: @posts.map(&:id)) }}
    @bans = Array.new(N) { create(:ban, banner: @admin) }
    @feedbacks = Array.new(N) { create(:user_feedback, creator: @mod) }
    @name_changes = Array.new(N) { create(:user_name_change_request) }
    @dmails = Array.new(N) { create(:dmail, owner: @restricted, to: @restricted) } + Array.new(N) { create(:dmail, owner: @member, to: @member) }
    @saved_searches = Array.new(N) { |i| create(:saved_search, user: @restricted, query: "tierfix_ss#{i}") } + Array.new(N) { |i| create(:saved_search, user: @member, query: "tierfix_ssm#{i}") }
    # The creator's own posts on their hero band, which wants tierfix_tag
    # (Creator Gallery rebuild, 2026-10-23: a band draws only posts the
    # creator controls and its tags fit).
    @gallery = create(:creator_gallery, slug: "tierfix-creator", settings: { "hero" => { "tags" => %w[tierfix_tag] }})
    @posts.each_with_index do |p, i|
      FourierPostCreator.create!(post: p, mxid: @gallery.matrix_id, recorded_by: p.uploader_id)
      CreatorGalleryPost.create!(creator_gallery: @gallery, post: p, band: "hero", position: i)
    end
    @galleries = [@gallery] + Array.new(N - 1) { |i| create(:creator_gallery, slug: "tierfix-c#{i}") }

    mock_iqdb_matches(@posts.map { |p| { post_id: p.id, score: 95.0 } })
    RecommenderService.stubs(:enabled?).returns(true)
    RecommenderService.stubs(:search).returns(@posts.map { |p| { post: p, score: 1.0 } })
  end

  context "Below full browsing" do
    setup do
      Danbooru.config.stubs(:restricted_browsing_per_page).returns(CAP)
      build_fixtures
    end

    should "be bounded on every surface" do
      failures = walk(SURFACES.keys)
      assert_empty(failures, "#{failures.size} leaks:\n#{failures.join("\n")}")
    end

    # A full account is not capped by the tier, but one page size is every
    # list's (operator, 2026-10-18): 200 a page, whatever it asks.
    should "give a full account 200 a page at most" do
      login_as(@member)
      get "/tags.json", params: { limit: 1000 }
      assert_response :success
      get "/posts.json", params: { limit: 1000, page: 2 }
      assert_response :success
      assert_equal(200, Tag.all.paginate(1, limit: 1000, viewer: @member).records_per_page)
    end

    should "say what the refusal is and how to get past it, not 'page 1000'" do
      login_as(@restricted)
      get "/tags", params: { page: 2 }
      assert_response 410
      assert_match(/one page/, response.body)
      assert_match(/full account/, response.body)
      assert_no_match(/page 1000/, response.body)
    end

    # The placeholder cards past the cut carry nothing of the posts they
    # stand for (operator, 2026-10-18: "view-source holds empty boxes").
    # Checked across the whole page, not only inside the cards: a wrapper, a
    # container attribute or a preload anywhere else would hold the post too.
    should "lay out the rest of a creator's gallery as empty cards" do
      { signed_out: /Sign in to see more!/, matrix: /Sign in to see more!/, restricted: /a full account sees the rest/i }.each do |viewer, sentence|
        become(viewer)
        get "/creators/#{@gallery.slug}", headers: @headers
        assert_response :success, viewer
        doc = Nokogiri::HTML5(response.body)
        locked = doc.css(".modcreator-card--locked")
        assert_equal(N - CAP, locked.size, viewer)
        assert_no_match(/href|src|data-/, locked.map(&:to_html).join, viewer)
        @posts.each_with_index.drop(CAP).each do |p, i|
          assert_not_includes(response.body, p.md5, "#{viewer}: post #{p.id}'s md5")
          assert_no_match(%r{/posts/#{p.id}(?!\d)}, response.body, "#{viewer}: a link to post #{p.id}")
          assert_empty(doc.css("[data-id='#{p.id}'], [data-post-id='#{p.id}']"), "#{viewer}: post #{p.id} named by an attribute")
          assert_not_includes(response.body, "tierfix_uniq#{i}", "#{viewer}: post #{p.id}'s own tag")
        end
        assert_match(sentence, response.body, viewer)
        assert_match(/#{N - CAP} more/, response.body, viewer)
      end
    end

    # The order editor draws the first page of the group; the rest go back
    # with the save by id, so a reorder never drops what was not drawn.
    should "draw a Restricted creator's order editor to the page, and keep the rest" do
      group = @own_groups.fetch(@restricted.id)
      login_as(@restricted)
      get "/favorite_groups/#{group.id}/order/edit"
      assert_response :success
      doc = Nokogiri::HTML5(response.body)
      drawn = doc.css("#sortable li[id]").map { |li| li["id"][/_(\d+)\z/, 1].to_i }
      kept = doc.css("#ordering-form input[type=hidden][name='favorite_group[post_ids][]']").map { |input| input["value"].to_i }
      assert_equal(@posts.map(&:id).first(CAP), drawn)
      assert_equal(@posts.map(&:id).drop(CAP), kept)

      put "/favorite_groups/#{group.id}.js", params: { favorite_group: { post_ids: drawn.reverse + kept }}, xhr: true
      assert_equal(drawn.reverse + kept, group.reload.post_ids)
    end
  end

  context "With MembersOnly on" do
    setup do
      Danbooru.config.stubs(:restricted_browsing_per_page).returns(CAP)
      Danbooru.config.stubs(:post_listings_members_only?).returns(true)
      Danbooru.config.stubs(:anonymous_default_deny?).returns(true)
      build_fixtures
    end

    # Presence first, then reach: a signed-out visitor is refused the door
    # (404) before the tier is asked; a Restricted account and a Matrix-only
    # reader get the tier's answer. A list naming posts is a member's
    # (MembersOnly.post_listing!), so to a Matrix-only reader, who has no
    # booru account, it is still presence's 404 -- the tier answers them on
    # every other list.
    should "refuse a signed-out visitor first, and bound everyone else" do
      become(:signed_out)
      get "/post_versions", params: { page: 2 }
      assert_response 404
      get "/tags", params: { page: 2 }
      assert_response 404

      become(:restricted)
      get "/post_versions", params: { page: 2 }
      assert_response 410
      get "/tags", params: { page: 2 }
      assert_response 410

      become(:matrix)
      get "/post_versions", params: { page: 2 }, headers: @headers
      assert_response 404
      get "/tags", params: { page: 2 }, headers: @headers
      assert_response 410
      get "/tags.json", params: { limit: 1000 }, headers: @headers
      assert_response :success
      assert_operator(response.parsed_body.size, :<=, CAP)
    end
  end

  context "The routes table" do
    should "classify every GET route, so a new list is walked above" do
      # ViewComponent's previews and system-test entrypoint exist only under
      # development and test (anonymous_default_deny_test's only_under_test?).
      under_test = ->(route) { route.internal || route.path.spec.to_s.start_with?("/_system_test_entrypoint") }
      gets = Rails.application.routes.routes.reject(&under_test).flat_map do |route|
        app = route.app.respond_to?(:app) ? route.app.app : route.app
        list = (app.is_a?(Class) && app < Rails::Engine) ? app.routes.routes.to_a : [route]
        list.select { |r| r.verb.to_s.split("|").then { |v| v.empty? || v.include?("GET") } && r.defaults[:controller] }
      end
      doors = gets.map { |r| "#{r.defaults[:controller]}##{r.defaults[:action]}" }.uniq
      # A route to an action its controller does not have answers 404 before
      # anything runs (upstream draws several); nothing is there to bound.
      live = doors.reject do |door|
        controller, action = door.split("#", 2)
        klass = "#{controller}_controller".camelize.safe_constantize
        klass.present? && !klass.new.available_action?(action)
      end

      unclassified = live.reject { |door| ROUTES.key?(door) || ENGINE_ROUTES.keys.any? { |prefix| door.start_with?(prefix) } }
      assert_empty(unclassified, unclassified.map { |door| "classify #{door}: a list of anything goes in SURFACES, so the tier's bound is checked on it" }.join("\n"))

      ROUTES.each do |door, entry|
        if Array(entry).all? { |e| SURFACES.key?(e) }
          next
        elsif entry.is_a?(Symbol) || CLASSES.exclude?(entry.first)
          flunk("#{door}: #{entry.inspect} is neither SURFACES rows nor a classification. Fix: name the SURFACES rows that walk it, or use one of #{CLASSES.inspect} with why")
        elsif entry.first == :exempt
          assert(PaginationExtension::TIER_EXEMPT.key?(entry.last), "#{door}: exempt names #{entry.last}, which is not in the registry. Fix: add it to PaginationExtension::TIER_EXEMPT with its reason, or classify the door otherwise")
        end
      end
      stale = ROUTES.keys - live
      assert_empty(stale, "ROUTES names doors the routes table no longer has: #{stale.join(", ")}. Fix: delete those entries")

      # Every row is walked from a door (or is a POST, which the GET table
      # does not hold): a row no door names measures a surface nobody reaches.
      named = ROUTES.values.flat_map { |entry| Array(entry) }
      orphans = SURFACES.reject { |name, row| row[:verb] == :post || named.include?(name) }.keys
      assert_empty(orphans, "SURFACES rows no door names: #{orphans.join(", ")}. Fix: name each under its controller#action in ROUTES")

      # A GET route with no controller is a redirect or the GoodJob engine;
      # anything else (a Rack app, a lambda) serves what this map cannot see.
      rack = Rails.application.routes.routes.reject(&under_test).select do |route|
        route.verb.to_s.split("|").then { |v| v.empty? || v.include?("GET") } && route.defaults[:controller].nil?
      end
      unseen = rack.reject do |route|
        app = route.app.respond_to?(:app) ? route.app.app : route.app
        (app.respond_to?(:redirect?) && app.redirect?) || (app.is_a?(Class) && app < Rails::Engine && app.routes.routes.any? { |r| ENGINE_ROUTES.keys.any? { |prefix| r.defaults[:controller].to_s.start_with?(prefix) } })
      end
      assert_empty(unseen.map { |r| r.path.spec.to_s }, "a GET route with no controller serves something the tier cannot see. Fix: give it a controller and classify it, or add its engine to ENGINE_ROUTES with why")
    end

    # The exemption is the hero band's, and only the hero band passes it: the
    # registry, the doors classified exempt and the code that opts out agree.
    should "let only the hero band's code pass tier_exempt" do
      uses = Rails.root.glob("app/**/*.{rb,erb}").flat_map do |file|
        File.readlines(file).filter_map { |line| [file.relative_path_from(Rails.root).to_s, $1.to_sym] if line =~ /tier_exempt: :(\w+)/ }
      end
      assert_equal(%w[app/logical/landing_showcase.rb app/logical/landing_showcase_cache.rb], uses.map(&:first).sort, "tier_exempt: is the hero band's (TIER_EXEMPT). Fix: bound the new surface instead, or add it to the registry with the operator's ruling")
      assert_equal(PaginationExtension::TIER_EXEMPT.keys, uses.map(&:last).uniq)
      assert_equal(PaginationExtension::TIER_EXEMPT.keys, ROUTES.values.select { |e| e.is_a?(Array) && e.first == :exempt }.map(&:last).uniq)
    end

    # A fixed list size above the tier's page, in a view, controller or
    # component, is a list paginate never sees (favorite_group_orders drew
    # 1,000). Each one either asks User#listing_per_page_limit or is named in
    # FIXED_SIZES with why.
    should "name no fixed list size above the tier's page" do
      page = Danbooru::Configuration.new.restricted_browsing_per_page
      over = Rails.root.glob("app/{views,controllers,components,helpers}/**/*.{rb,erb}").flat_map do |file|
        File.readlines(file).each_with_index.filter_map do |line, i|
          size = line[/\.(?:limit|take)\(([\d_]+)\)/, 1]&.delete("_")&.to_i
          "#{file.relative_path_from(Rails.root)}:#{i + 1}" if size && size > page && line.exclude?("listing_per_page_limit")
        end
      end
      unnamed = over.reject { |at| FIXED_SIZES.key?(at.split(":").first) }
      assert_empty(unnamed, "a fixed list size above #{page}. Fix: bound it by CurrentUser.user.listing_per_page_limit, or name the file in FIXED_SIZES with why")
    end
  end
end
