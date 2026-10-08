# frozen_string_literal: true

require "test_helper"

# THE DECISION (design CREATOR_VISIBILITY sections 4, 5, 7 and 9, ruled
# 2026-10-07): for a post and a viewer, does the creator's panel hide it
# (narrow), explicitly allow it (the input to widen), or have no opinion past
# the site's own rules? Every branch is asked here, and every case is asked
# through every shape -- per post, the batch over candidates, and the whole
# set for a viewer -- because enforcement will use the batch forms and they
# must never disagree with the per-post one.
class CreatorVisibilityTest < ActiveSupport::TestCase
  def gallery_for(user, mxid)
    CreatorGallery.create!(matrix_id: mxid, slug: mxid.gsub(/[^a-z0-9]/, "-"), user: user)
  end

  def post_tagged(tags, creator: nil)
    post = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: tags) }
    FourierPostCreator.create!(post: post, mxid: creator, recorded_by: @tunnel.id) if creator
    post
  end

  def maple_post(tags = "landscape") = post_tagged(tags, creator: "@maple:41chan.net")

  def approved_claim(gallery, tag)
    artist = Artist.find_by(name: tag) || as(@admin) { create(:artist, name: tag) }
    ArtistClaim.create!(artist: artist, creator_gallery: gallery).tap { |c| c.approve!(by: @admin) }
  end

  def group(name, tier: nil, gallery: @maple_gallery)
    CreatorGroup.make!(gallery, name: name, tier: tier, by: @admin)
  end

  def join(group, user, expires_at: nil)
    group.add_member!(user, by: @admin, expires_at: expires_at)
  end

  def default!(audience, groups = [], gallery: @maple_gallery)
    gallery.set_default_audience!(audience, by: @admin, group_ids: groups.map(&:id))
  end

  def override!(post, audience, groups = [], gallery: @maple_gallery)
    CreatorPostAudience.set!(post, gallery: gallery, audience: audience, by: @admin, group_ids: groups.map(&:id))
  end

  def rule!(user, rule, post: nil, gallery: @maple_gallery)
    CreatorUserRule.set!(gallery, user, rule: rule, by: @admin, post: post)
  end

  delegate :decide, to: :CreatorVisibility

  # Every shape must give the per-post answer, row for row.
  def assert_agrees(viewer, posts)
    per_post = posts.to_h { |p| [p.id, decide(p, viewer)] }
    hidden = per_post.select { |_, d| d == :hidden }.keys.sort

    assert_equal(per_post, CreatorVisibility.decisions(posts, viewer), "decisions disagrees with decide for #{viewer&.name.inspect}")
    assert_equal(hidden, CreatorVisibility.hidden_post_ids(posts, viewer), "hidden_post_ids disagrees with decide for #{viewer&.name.inspect}")
    assert_equal(hidden, CreatorVisibility.hidden_post_ids_for(viewer) & posts.map(&:id), "hidden_post_ids_for disagrees with decide for #{viewer&.name.inspect}")
  end

  # Every query the code issues, including those the query cache answers:
  # what is measured is how many the code asks, not how many reach the server.
  def queries_during(&)
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &)
    count
  end

  setup do
    CreatorPrefixes.reset!
    CreatorTagRelease.reset_cache!
    @tunnel = create(:builder_user, name: "tunnel")
    @admin = create(:admin_user)
    @maple = create(:user)
    @alice = create(:user)
    @member = create(:user)
    @stranger = create(:user)
    @maple_gallery = gallery_for(@maple, "@maple:41chan.net")
    @alice_gallery = gallery_for(@alice, "@alice:41chan.net")
    @post = maple_post
  end

  context "a post nobody controls" do
    should "carry no creator opinion for anyone" do
      post = post_tagged("landscape")
      default!("private")

      [@stranger, @member, User.anonymous, nil].each { |viewer| assert_equal(:default, decide(post, viewer)) }
      assert_agrees(@stranger, [post])
    end

    # As CreatorControl.controls? answers one: a post not yet saved has no
    # controller.
    should "carry no creator opinion on an unsaved post" do
      default!("private")

      assert_equal(:default, decide(Post.new(tag_string: "landscape"), @stranger))
    end
  end

  context "the creator default" do
    should "be public until the creator says otherwise: no opinion, for anyone" do
      [@stranger, User.anonymous, nil].each { |viewer| assert_equal(:default, decide(@post, viewer)) }
      assert_agrees(@stranger, [@post])
    end

    # Section 4: private is "the creator alone" -- not their groups, not the
    # users they name; narrowest wins.
    should "hide a private creator's posts from everyone but the creator" do
      tier = group("41chan_maple_tier_1", tier: 1)
      join(tier, @member)
      rule!(@stranger, "allow")
      rule!(@member, "allow", post: @post)
      default!("private")

      [@stranger, @member, User.anonymous, nil].each { |viewer| assert_equal(:hidden, decide(@post, viewer), viewer&.name) }
      assert_equal(:allowed, decide(@post, @maple))
      assert_agrees(@member, [@post])
      assert_agrees(@stranger, [@post])
    end

    # Unset (never chosen) and an explicit public decide alike; the column
    # keeps them apart for the Matrix-image door (Q7).
    should "decide an unset default as public" do
      assert_nil(@maple_gallery.reload.default_audience)
      assert_equal(:default, decide(@post, @stranger))
      default!("public")

      assert_equal(:default, decide(@post, @stranger))
      assert_agrees(@stranger, [@post])
    end

    should "hide a groups-only creator's posts from all but members of a listed group" do
      tier = group("41chan_maple_tier_1", tier: 1)
      unlisted = group("41chan_maple_friends")
      join(tier, @member)
      join(unlisted, @stranger)
      default!("groups", [tier])

      assert_equal(:allowed, decide(@post, @member))
      assert_equal(:hidden, decide(@post, @stranger))
      assert_equal(:hidden, decide(@post, User.anonymous))
      assert_agrees(@member, [@post])
      assert_agrees(@stranger, [@post])
    end

    should "hide a groups-only creator's posts from everyone when no group is listed" do
      default!("groups")

      assert_equal(:hidden, decide(@post, @stranger))
      assert_agrees(@stranger, [@post])
    end

    # Section 7: "public" on its own widens nothing; a named group does.
    should "let a public creator's listed groups be allowed, and leave everyone else at the site's rules" do
      tier = group("41chan_maple_tier_1", tier: 1)
      join(tier, @member)
      default!("public", [tier])

      assert_equal(:allowed, decide(@post, @member))
      assert_equal(:default, decide(@post, @stranger))
      assert_agrees(@member, [@post])
    end
  end

  context "groups" do
    setup do
      @tier1 = group("41chan_maple_tier_1", tier: 1)
      @tier2 = group("41chan_maple_tier_2", tier: 2)
      @friends = group("41chan_maple_friends")
    end

    # Q3: tier_2 sees everything tier_1 sees.
    should "nest by tier: a higher tier sees what a lower tier was granted, never the reverse" do
      join(@tier2, @member)
      join(@tier1, @stranger)
      default!("groups", [@tier1])
      upper = maple_post
      override!(upper, "groups", [@tier2])

      assert_equal(:allowed, decide(@post, @member))
      assert_equal(:allowed, decide(upper, @member))
      assert_equal(:allowed, decide(@post, @stranger))
      assert_equal(:hidden, decide(upper, @stranger))
      assert_agrees(@member, [@post, upper])
      assert_agrees(@stranger, [@post, upper])
    end

    should "keep an untiered group independent of the tiers, both ways" do
      join(@tier2, @member)
      join(@friends, @stranger)
      default!("groups", [@friends])
      tiered = maple_post
      override!(tiered, "groups", [@tier1])

      assert_equal(:hidden, decide(@post, @member))
      assert_equal(:allowed, decide(@post, @stranger))
      assert_equal(:hidden, decide(tiered, @stranger))
      assert_agrees(@member, [@post, tiered])
      assert_agrees(@stranger, [@post, tiered])
    end

    should "nest only within one creator: another creator's higher tier counts for nothing" do
      alices = group("41chan_alice_tier_3", tier: 3, gallery: @alice_gallery)
      join(alices, @member)
      default!("groups", [@tier1])

      assert_equal(:hidden, decide(@post, @member))
      assert_agrees(@member, [@post])
    end

    # Section 5: an expired membership ends access by itself, no job.
    should "count a membership only until it expires" do
      join(@tier1, @member, expires_at: 1.day.from_now)
      default!("groups", [@tier1])

      assert_equal(:allowed, decide(@post, @member))
      travel(2.days) do
        assert_equal(:hidden, decide(@post, @member))
        assert_agrees(@member, [@post])
      end
    end

    should "count an already-expired membership as no membership" do
      join(@tier2, @member, expires_at: 1.minute.ago)
      default!("groups", [@tier1])

      assert_equal(:hidden, decide(@post, @member))
      assert_agrees(@member, [@post])
    end
  end

  context "a per-post override" do
    should "beat the creator default, in both directions" do
      default!("public")
      narrowed = maple_post
      override!(narrowed, "private")
      default!("private")
      opened = maple_post
      override!(opened, "public")

      assert_equal(:hidden, decide(narrowed, @stranger))
      assert_equal(:default, decide(opened, @stranger))
      assert_agrees(@stranger, [narrowed, opened])
    end

    should "widen a public override to its own listed groups only" do
      tier1 = group("41chan_maple_tier_1", tier: 1)
      join(tier1, @member)
      override!(@post, "public", [tier1])

      assert_equal(:allowed, decide(@post, @member))
      assert_equal(:default, decide(@post, @stranger))
      assert_agrees(@member, [@post])
      assert_agrees(@stranger, [@post])
    end

    should "fall back to the creator default when it says inherit" do
      default!("private")
      override!(@post, "inherit")

      assert_equal(:hidden, decide(@post, @stranger))
      assert_agrees(@stranger, [@post])
    end

    should "use its own groups, not the default's" do
      tier1 = group("41chan_maple_tier_1", tier: 1)
      friends = group("41chan_maple_friends")
      join(tier1, @stranger)
      join(friends, @member)
      default!("groups", [tier1])
      override!(@post, "groups", [friends])

      assert_equal(:allowed, decide(@post, @member))
      assert_equal(:hidden, decide(@post, @stranger))
      assert_agrees(@member, [@post])
      assert_agrees(@stranger, [@post])
    end

    # One controller decides a post; a row written while someone else held
    # control (a claim since withdrawn) is not theirs to apply.
    should "count only when written by a gallery that controls the post now" do
      override!(@post, "private")
      CreatorPostAudience.find_by!(post: @post).update_columns(creator_gallery_id: @alice_gallery.id) # rubocop:disable Rails/SkipsModelValidations

      assert_equal(:default, decide(@post, @stranger))
      assert_agrees(@stranger, [@post])
    end
  end

  context "per-user rules" do
    # Q1: a named user widens a public post past the site's gates.
    should "widen a public post to a named user, creator-wide or on one post" do
      other = maple_post
      rule!(@member, "allow")
      rule!(@stranger, "allow", post: @post)

      assert_equal(:allowed, decide(@post, @member))
      assert_equal(:allowed, decide(other, @member))
      assert_equal(:allowed, decide(@post, @stranger))
      assert_equal(:default, decide(other, @stranger))
      assert_agrees(@member, [@post, other])
      assert_agrees(@stranger, [@post, other])
    end

    # Section 4: narrowest wins between the levels -- a named user does not
    # open what the audience closes.
    should "not open a private or groups-only post to a named user" do
      tier = group("41chan_maple_tier_1", tier: 1)
      default!("groups", [tier])
      closed = maple_post
      override!(closed, "private")
      rule!(@member, "allow")
      rule!(@stranger, "allow", post: closed)

      assert_equal(:hidden, decide(@post, @member))
      assert_equal(:hidden, decide(closed, @member))
      assert_equal(:hidden, decide(closed, @stranger))
      assert_agrees(@member, [@post, closed])
      assert_agrees(@stranger, [@post, closed])
    end

    # A post's override replaces the creator default -- the audience and its
    # groups -- and nothing else: the creator's named users are a level of
    # their own (section 4). Blocks apply everywhere.
    should "carry a creator-wide allow onto a post whose override replaced only the audience" do
      rule!(@member, "allow")
      override!(@post, "public")

      assert_equal(:allowed, decide(@post, @member))
      assert_agrees(@member, [@post])
    end

    should "let a post-scoped allow open its post under a public override, and only for its user" do
      default!("private")
      override!(@post, "public")
      rule!(@member, "allow", post: @post)

      assert_equal(:allowed, decide(@post, @member))
      assert_equal(:default, decide(@post, @stranger))
      assert_agrees(@member, [@post])
      assert_agrees(@stranger, [@post])
    end

    should "let a block beat every allow: creator-wide, per post and group" do
      tier = group("41chan_maple_tier_1", tier: 1)
      join(tier, @member)
      default!("groups", [tier])
      rule!(@member, "allow")
      rule!(@member, "allow", post: @post)
      other = maple_post
      rule!(@member, "block", post: other)

      assert_equal(:allowed, decide(@post, @member))
      assert_equal(:hidden, decide(other, @member))

      rule!(@member, "block")

      assert_equal(:hidden, decide(@post, @member))
      assert_agrees(@member, [@post, other])
    end

    # Q8: blocked while signed in, the account cannot see the post, and so
    # cannot edit it.
    should "hide a public post from a blocked account" do
      rule!(@member, "block")

      assert_equal(:hidden, decide(@post, @member))
      assert_equal(:default, decide(@post, @stranger))
      assert_agrees(@member, [@post])
    end

    should "be scoped to their creator" do
      default!("private", gallery: @alice_gallery)
      rule!(@member, "allow", gallery: @alice_gallery)
      default!("private")

      assert_equal(:hidden, decide(@post, @member))
      assert_agrees(@member, [@post])
    end
  end

  context "who always sees" do
    setup do
      default!("private")
      rule!(@admin, "block")
      rule!(@tunnel, "block")
    end

    should "be the controller, explicitly allowed" do
      assert_equal(:allowed, decide(@post, @maple))
      assert_agrees(@maple, [@post])
    end

    # Q2: admins only may view a post its creator hid (enforcement logs it).
    should "include admins, even blocked ones, but not moderators" do
      moderator = create(:moderator_user)

      assert_equal(:default, decide(@post, @admin))
      assert_equal(:hidden, decide(@post, moderator))
      assert_agrees(@admin, [@post])
      assert_agrees(moderator, [@post])
    end

    # So a re-upload is never refused.
    should "include the posting bots (the prefix list's editors), even blocked ones" do
      sample = create(:user, name: "sample")

      assert_equal(:default, decide(@post, @tunnel))
      assert_equal(:default, decide(@post, sample))
      assert_agrees(@tunnel, [@post])
    end
  end

  context "what widening never reaches" do
    setup do
      @tier = group("41chan_maple_tier_1", tier: 1)
      join(@tier, @member)
      default!("public", [@tier])
    end

    should "never allow a signed-out visitor" do
      assert_equal(:default, decide(@post, User.anonymous))
      assert_equal(:default, decide(@post, nil))
      assert_agrees(User.anonymous, [@post])
    end

    should "never allow a banned viewer, though their allow still stands" do
      @member.update!(is_banned: true)
      rule!(@member, "allow")

      assert_equal(:default, decide(@post, @member))
      assert_agrees(@member, [@post])
    end

    should "never allow a banned controller" do
      @maple.update!(is_banned: true)

      assert_equal(:default, decide(@post, @maple))
    end

    should "never allow anyone on a jailed post, while a narrowing still hides it" do
      jailed = maple_post("landscape #{Danbooru.config.troll_jail_tag}")
      hidden = maple_post("landscape #{Danbooru.config.troll_jail_tag}")
      override!(hidden, "groups", [])

      assert_equal(:default, decide(jailed, @member))
      assert_equal(:default, decide(jailed, @maple))
      assert_equal(:hidden, decide(hidden, @member))
      assert_agrees(@member, [jailed, hidden])
    end

    # Jail is every TagBanishment.post_tags name, not only the jail tag.
    should "never allow anyone on a post carrying a banished tag" do
      banished = maple_post("landscape gore_thing")
      Danbooru.config.stubs(:banished_tags).returns(["gore_thing"])

      assert_equal(:default, decide(banished, @member))
      assert_equal(:allowed, decide(@post, @member))
      assert_agrees(@member, [banished, @post])
    end

    # Never allowed is not never hidden: a narrowing reaches them as anyone.
    should "still hide from a banned or signed-out viewer what the creator narrowed" do
      banned = create(:banned_user)
      blocked = maple_post
      rule!(banned, "block", post: blocked)
      closed = maple_post
      override!(closed, "private")

      assert_equal(:hidden, decide(blocked, banned))
      [banned, User.anonymous, nil].each { |viewer| assert_equal(:hidden, decide(closed, viewer), viewer&.name) }
      assert_agrees(banned, [blocked, closed])
      assert_agrees(User.anonymous, [closed])
    end
  end

  # Section 9: two controllers on one post -- narrowest wins.
  context "a post two creators control" do
    setup do
      approved_claim(@maple_gallery, "4chan_maple")
      approved_claim(@alice_gallery, "4chan_alice")
      @shared = post_tagged("4chan_maple 4chan_alice landscape")
      @maple_tier = group("41chan_maple_tier_1", tier: 1)
      @alice_tier = group("41chan_alice_tier_1", tier: 1, gallery: @alice_gallery)
    end

    should "be hidden when either one hides it, and seen by both controllers" do
      default!("private")

      assert_equal(:hidden, decide(@shared, @stranger))
      assert_equal(:allowed, decide(@shared, @alice))
      assert_equal(:allowed, decide(@shared, @maple))
      assert_agrees(@stranger, [@shared])
      assert_agrees(@alice, [@shared])
    end

    should "be allowed only when both allow" do
      join(@maple_tier, @member)
      default!("public", [@maple_tier])

      assert_equal(:default, decide(@shared, @member))

      join(@alice_tier, @member)
      default!("public", [@alice_tier], gallery: @alice_gallery)

      assert_equal(:allowed, decide(@shared, @member))
      assert_agrees(@member, [@shared])
    end

    # Each controller's override is its own: the second to set one does not
    # erase the first's (section 9, narrowest wins).
    should "keep both controllers' overrides, and hide when either does" do
      override!(@shared, "private")
      join(@alice_tier, @member)
      override!(@shared, "public", [@alice_tier], gallery: @alice_gallery)

      assert_equal(:hidden, decide(@shared, @stranger))
      assert_equal(:hidden, decide(@shared, @member))
      assert_agrees(@stranger, [@shared])
      assert_agrees(@member, [@shared])

      override!(@shared, "public", [@maple_tier])
      join(@maple_tier, @member)

      assert_equal(:allowed, decide(@shared, @member))
      assert_equal(:default, decide(@shared, @stranger))
      assert_agrees(@member, [@shared])
    end
  end

  # A prefix shown to members only (CreatorPrefixes::VISIBILITIES): the same
  # release rule, where the prefix default is not already admins-only.
  context "a creator under a members-only prefix" do
    setup do
      @dir = Dir.mktmpdir("creator-visibility-prefixes")
      @path = File.join(@dir, "creator_prefixes.yml")
      @was = ENV.fetch("FOURIER_CREATOR_PREFIXES", nil)
      File.write(@path, <<~YAML)
        editors: [tunnel]
        prefixes:
          - {prefix: 41chan_, provenance: Matrix, target_kind: server, target: matrix.41chan.net, scope: x}
          - {prefix: memchan_, provenance: Discord, target_kind: server, target: MemChan, scope: x, visible_to: members}
      YAML
      ENV["FOURIER_CREATOR_PREFIXES"] = @path
      CreatorPrefixes.reset!
      approved_claim(@maple_gallery, "memchan_maple")
      @mem = post_tagged("memchan_maple landscape")
      tier = group("41chan_maple_tier_1", tier: 1)
      join(tier, @member)
      default!("private")
      rule!(@stranger, "block")
      override!(@mem, "public", [tier])
    end

    teardown do
      ENV["FOURIER_CREATOR_PREFIXES"] = @was
      CreatorPrefixes.reset!
      FileUtils.rm_rf(@dir)
    end

    # Q8: a block beats every allow, released or not.
    should "keep a block and a private default while unreleased, and widen nothing" do
      private_one = post_tagged("memchan_maple portrait")

      assert_equal(:hidden, decide(@mem, @stranger))
      assert_equal(:hidden, decide(private_one, @alice))
      assert_equal(:default, decide(@mem, @member))
      assert_agrees(@stranger, [@mem, private_one])
      assert_agrees(@member, [@mem, private_one])
    end

    should "widen once released" do
      CreatorTagRelease.set!("memchan_maple", released: true, by: @admin)

      assert_equal(:allowed, decide(@mem, @member))
      assert_equal(:hidden, decide(@mem, @stranger))
      assert_agrees(@member, [@mem])
    end
  end

  # Section 7: the panel's widening sits AFTER the release check.
  context "a creator under a hidden prefix" do
    setup do
      approved_claim(@maple_gallery, "aichan_maple")
      @ai = post_tagged("aichan_maple landscape")
      tier = group("41chan_maple_tier_1", tier: 1)
      join(tier, @member)
      default!("groups", [tier])
    end

    # "Nothing in the panel widens it" -- and "a creator's restriction always
    # narrows" (section 7): unreleased, the panel's narrowing still stands.
    should "widen nothing until released, while its narrowing still hides" do
      assert_equal(:hidden, decide(@ai, @stranger))
      assert_equal(:default, decide(@ai, @member))
      assert_equal(:default, decide(@ai, @maple))
      assert_agrees(@stranger, [@ai])
      assert_agrees(@member, [@ai])
    end

    # The release is the controlling creator's own: another creator's held
    # back tag on a post neither lifts its controller's narrowing nor caps
    # its controller's widening.
    should "judge only the controller's own creator tags" do
      bob = create(:user)
      approved_claim(gallery_for(bob, "@bob:41chan.net"), "aichan_bob")
      foreign = maple_post("landscape aichan_bob")
      blocked = maple_post("landscape aichan_bob")
      rule!(bob, "block", post: blocked)

      assert_equal(:hidden, decide(foreign, bob))
      assert_equal(:hidden, decide(blocked, bob))
      assert_equal(:allowed, decide(foreign, @member))
      assert_agrees(bob, [foreign, blocked])
      assert_agrees(@member, [foreign])
    end

    should "be decided by the panel once released" do
      CreatorTagRelease.set!("aichan_maple", released: true, by: @admin)

      assert_equal(:hidden, decide(@ai, @stranger))
      assert_equal(:allowed, decide(@ai, @member))
      assert_agrees(@stranger, [@ai])
      assert_agrees(@member, [@ai])
    end
  end

  context "the batch forms" do
    setup do
      @tier1 = group("41chan_maple_tier_1", tier: 1)
      @tier2 = group("41chan_maple_tier_2", tier: 2)
      @friends = group("41chan_maple_friends")
      join(@tier2, @member)
      join(@friends, @stranger, expires_at: 1.day.ago)
      default!("groups", [@tier1])
      approved_claim(@alice_gallery, "4chan_alice")
      approved_claim(@maple_gallery, "4chan_maple")
      default!("public", gallery: @alice_gallery)

      @posts = [@post]
      @posts << maple_post.tap { |p| override!(p, "public") }
      @posts << maple_post.tap { |p| override!(p, "groups", [@friends]) }
      @posts << maple_post.tap { |p| override!(p, "private") }
      @posts << maple_post("landscape #{Danbooru.config.troll_jail_tag}")
      @posts << post_tagged("4chan_alice landscape")
      @posts << post_tagged("4chan_alice 4chan_maple landscape")
      @posts << post_tagged("landscape")
      rule!(@stranger, "allow", post: @posts[3])
      rule!(@member, "block", post: @posts[1])
      rule!(@stranger, "block", gallery: @alice_gallery)
      override!(@posts[6], "public", [@tier2])
      override!(@posts[6], "private", gallery: @alice_gallery)
    end

    should "agree with the per-post form for every viewer" do
      [@maple, @alice, @member, @stranger, @admin, @tunnel, create(:banned_user), User.anonymous, nil].each do |viewer|
        assert_agrees(viewer, @posts)
      end
    end

    # Each set holds every shape (recorded creator, claimed tag, override,
    # nobody), so no query is skipped in one run and made in the other. One
    # call first, so the release list's own memo is warm for both.
    should "answer many posts in the same number of queries as few" do
      few_posts = [@posts[0], @posts[1], @posts[5], @posts[7]]
      many_posts = @posts + Array.new(4) { maple_post }
      CreatorVisibility.decisions(many_posts, @member)
      few = queries_during { CreatorVisibility.decisions(few_posts, @member) }
      many = queries_during { CreatorVisibility.decisions(many_posts, @member) }

      assert_operator(few, :>, 0)
      assert_equal(few, many)
    end
  end
end
