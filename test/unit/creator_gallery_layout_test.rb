# frozen_string_literal: true

require "test_helper"

# The creator's own gallery page (Creator Gallery rebuild, 2026-10-23): a
# hero band whose tags define its candidates, minibands of one tag each, a
# banner and the depth settings, saved as one look. Only ELIGIBLE posts are
# choices -- the creator's own, media, live, and public by the creator's own
# records (operator ruling: a private post is not a valid option) -- and the
# draw then filters per viewer like every other showcase.
class CreatorGalleryLayoutTest < ActiveSupport::TestCase
  MXID = "@maple:41chan.net"

  def post_with(tags, creator: MXID, **attrs)
    post = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: tags, rating: "g", **attrs) }
    FourierPostCreator.create!(post: post, mxid: creator, recorded_by: @tunnel.id) if creator
    post
  end

  def choose(band, posts)
    posts.each_with_index { |post, i| @gallery.creator_gallery_posts.create!(band: band, post: post, position: i) }
  end

  def layout = CreatorGalleryLayout.new(@gallery.reload)

  # A complete, valid look over the setup's posts; each test spoils one part.
  def look(**over)
    {
      "headline" => "After Hours", "subline" => "Night trains",
      "banner" => { "post_id" => @posts.first.id, "y" => 40 },
      "depth" => { "blur" => 20, "dim" => 40, "parallax" => 60 },
      "hero" => { "tags" => %w[night wren ivo], "effect" => "depth", "dir" => "right", "hold" => 6, "cells" => 7, "posts" => @posts.map(&:id) },
      "layout" => "1-2",
      "minis" => [
        { "tag" => "rain", "effect" => "fade", "dir" => "up", "hold" => 4, "posts" => @posts.first(3).map(&:id) },
        { "tag" => "snow", "effect" => "flip", "dir" => "down", "hold" => 7, "posts" => @posts.last(3).map(&:id) },
        { "tag" => "night", "effect" => "slide", "dir" => "left", "hold" => 5, "posts" => [@posts.first.id] },
      ],
    }.merge(over.transform_keys(&:to_s))
  end

  def hero(**over) = look["hero"].merge(over.transform_keys(&:to_s))

  def ids(slides) = slides.pluck(:id)

  # The request of a curator signed in through Matrix as `mxid`.
  def as_matrix(mxid = MXID, &) = CurrentUser.set(request: ActionDispatch::TestRequest.create(FourierIdentity::HEADER => mxid), &)

  def profile(body, status: 200)
    HTTP::Response.new(status: status, body: body.to_json, version: "1.1", request: nil, headers: { "Content-Type" => "application/json" })
  end

  setup do
    @tunnel = create(:contributor_user, name: "tunnel")
    @admin = create(:admin_user)
    @maple = create(:user)
    @gallery = CreatorGallery.create!(slug: "maple", matrix_id: MXID, user: @maple)
    create(:tag, name: "wren", category: Tag.categories.character)
    create(:tag, name: "ivo", category: Tag.categories.character)
    # Six posts: night neon on all, wren on the first three (with rain), ivo
    # on the last three (with snow).
    @posts = Array.new(6) { |i| post_with((i < 3) ? "night neon wren rain" : "night neon ivo snow") }
  end

  context "The band rule" do
    should "want every general tag on the post and any one of the characters" do
      rule = layout.rule(%w[night wren ivo])

      assert_equal(%w[night], rule.general)
      assert_equal(%w[wren ivo], rule.characters)
      assert(@posts.all? { |post| rule.fits?(post) })
      assert_not(rule.fits?(post_with("neon wren")), "lacks the general tag night")
      assert_not(rule.fits?(post_with("night neon")), "carries none of the characters")
    end

    should "fit nothing when it has no tags, and a miniband's one tag alone" do
      assert_not(layout.rule([]).fits?(@posts.first))
      assert(layout.rule(%w[rain]).fits?(@posts.first))
      assert_not(layout.rule(%w[rain]).fits?(@posts.last))
    end
  end

  context "Eligibility" do
    should "offer the gallery's own live media posts, newest first, and nothing else" do
      others = post_with("night neon wren", creator: "@alice:41chan.net")
      deleted = post_with("night neon wren", is_deleted: true)
      flash = post_with("night neon wren")
      flash.update_columns(file_ext: "swf") # rubocop:disable Rails/SkipsModelValidations -- a file type no upload would accept here
      jailed = post_with("night neon wren")
      jailed.update_columns(tag_string: "#{jailed.tag_string} #{Danbooru.config.troll_jail_tag}") # rubocop:disable Rails/SkipsModelValidations -- past the jail callbacks, as an old post stands

      found = layout.candidates([], @maple)

      assert_equal(@posts.map(&:id).reverse, ids(found[:slides]))
      assert_equal(6, found[:total])
      assert_equal(300, found[:cap])
      [others, deleted, flash, jailed].each { |post| assert_not_includes(ids(found[:slides]), post.id) }
    end

    should "narrow the candidates by the band rule and say the total past the cap" do
      found = layout.candidates(%w[night wren], @maple, limit: 2)

      assert_equal(3, found[:total])
      assert_equal(2, found[:cap])
      assert_equal(@posts.first(3).map(&:id).reverse.first(2), ids(found[:slides]))
    end

    should "leave out a post whose creator-set audience is private or groups" do
      CreatorPostAudience.set!(@posts[0], gallery: @gallery, audience: "private", by: @maple)
      tier = CreatorGroup.make!(@gallery, name: "41chan_maple_tier_1", tier: 1, by: @maple)
      CreatorPostAudience.set!(@posts[1], gallery: @gallery, audience: "groups", by: @maple, group_ids: [tier.id])

      assert_equal(@posts.drop(2).map(&:id).reverse, ids(layout.candidates([], @maple)[:slides]))
    end

    should "under a private default, offer only the posts the creator made public" do
      @gallery.set_default_audience!("private", by: @maple)
      CreatorPostAudience.set!(@posts[3], gallery: @gallery, audience: "public", by: @maple)

      assert_equal([@posts[3].id], ids(layout.candidates([], @maple)[:slides]))
    end

    # The trap the ruling names: a curator signed in only through Matrix makes
    # a viewer-based check treat the signed-out user as the curator, who sees
    # their own private posts. Eligibility reads the records, not a viewer.
    should "leave out a private post while the curator is signed in through Matrix only" do
      CreatorPostAudience.set!(@posts[0], gallery: @gallery, audience: "private", by: @maple)
      choose("hero", @posts)
      request = ActionDispatch::TestRequest.create(FourierIdentity::HEADER => MXID)

      CurrentUser.set(user: User.anonymous, request: request) do
        assert_not_includes(ids(layout.candidates([], User.anonymous)[:slides]), @posts[0].id)
        assert_not_includes(ids(layout.draw(User.anonymous)[:hero][:slides]), @posts[0].id)
        # An admin sees every private post, so only the records can drop it.
        assert_not_includes(ids(layout.candidates([], @admin)[:slides]), @posts[0].id)
        assert_not_includes(ids(layout.draw(@admin)[:hero][:slides]), @posts[0].id)
      end
    end

    # Narrowest wins between a post's controllers (CreatorVisibility): a post
    # another gallery also controls and keeps from signed-out viewers is
    # hidden from them whatever this gallery says, so it is no choice here.
    should "leave out a post another controlling gallery keeps from signed-out viewers, and say why" do
      alice = CreatorGallery.create!(slug: "alice", matrix_id: "@alice:41chan.net", user: create(:user))
      kept, shared = Array.new(2) { post_with("night neon wren rain 41chan_maple 41chan_alice", creator: nil) }
      CreatorPostAudience.set!(shared, gallery: alice, audience: "private", by: alice.user)

      found = ids(layout.candidates([], @maple)[:slides])
      assert_includes(found, kept.id)
      assert_not_includes(found, shared.id)
      assert_includes(layout.save(viewer: @maple, page: {}, look: look("hero" => hero("posts" => [*@posts.map(&:id), shared.id]))),
                      "Post ##{shared.id} cannot be chosen: another creator who shares it keeps it from signed-out viewers. Take it off.")
    end

    # The count is an answer too: a post or a tag hidden from the curator is
    # not counted, and a band asking for a hidden tag has nothing to count.
    should "count neither a post nor a tag hidden from the curator" do
      Danbooru.config.stubs(:restricted_tags).returns(%w[snow])

      assert_equal({ total: 0, cap: 300, slides: [] }, layout.candidates(%w[snow], User.anonymous))
      assert_equal(3, layout.candidates([], User.anonymous)[:total])
      assert_equal(3, layout.candidates(%w[snow], @admin)[:total])
    end

    # The curator chooses for everyone, but is shown only what they may see:
    # a post the showcase gate keeps from them is not offered them, and the
    # total still counts it.
    should "offer the curator only the candidates they may see" do
      @posts[5].update_columns(is_banned: true) # rubocop:disable Rails/SkipsModelValidations

      assert_not_includes(ids(layout.candidates([], User.anonymous)[:slides]), @posts[5].id)
      assert_equal(6, layout.candidates([], User.anonymous)[:total])
      assert_includes(ids(layout.candidates([], @admin)[:slides]), @posts[5].id)
    end
  end

  context "The palette" do
    should "count the tags over the eligible posts, with their categories, and no private tag" do
      FourierTagSource.create!(post: @posts[0], tag: "secret_sauce", source: FourierTagSource::CREATOR, status: FourierTagSource::APPROVED, public: false)
      post_with("night elsewhere", creator: "@alice:41chan.net")

      palette = layout.palette(@maple)

      assert_equal({ name: "neon", category: "general", count: 6 }, palette.find { |row| row[:name] == "neon" })
      assert_equal({ name: "wren", category: "character", count: 3 }, palette.find { |row| row[:name] == "wren" })
      assert_nil(palette.find { |row| row[:name] == "secret_sauce" })
      assert_nil(palette.find { |row| row[:name] == "elsewhere" })
      assert_equal(%w[neon night], palette.first(2).pluck(:name).sort)
    end

    should "count no post whose audience is private, and offer no tag only those carry" do
      hushed = post_with("night neon hush")
      CreatorPostAudience.set!(hushed, gallery: @gallery, audience: "private", by: @maple)

      assert_nil(layout.palette(@maple).find { |row| row[:name] == "hush" })
      assert_equal(6, layout.palette(@maple).find { |row| row[:name] == "night" }[:count])
      assert_nil(layout.palette(@admin).find { |row| row[:name] == "hush" })
    end

    should "leave out a tag the curator may not see" do
      Danbooru.config.stubs(:restricted_tags).returns(%w[snow])

      assert_nil(layout.palette(User.anonymous).find { |row| row[:name] == "snow" })
      assert_nil(layout.palette(User.anonymous).find { |row| row[:name] == "ivo" }, "carried only by posts hidden from the curator")
      assert_equal(3, layout.palette(User.anonymous).find { |row| row[:name] == "night" }[:count])
      assert_equal(3, layout.palette(@admin).find { |row| row[:name] == "snow" }[:count])
    end
  end

  context "The draw" do
    setup do
      @gallery.update!(settings: { "hero" => { "tags" => %w[night wren ivo] }, "layout" => "1-2", "minis" => [{ "tag" => "rain" }, { "tag" => "snow" }] })
      choose("hero", @posts)
      choose("mini1", @posts.first(2))
      choose("mini2", [@posts.last])
    end

    should "draw each band's chosen posts in order, with its tags and their categories" do
      drawn = layout.draw(@admin)

      assert_equal(@posts.map(&:id), ids(drawn[:hero][:slides]))
      assert_equal([{ name: "night", category: "general" }, { name: "wren", category: "character" }, { name: "ivo", category: "character" }], drawn[:hero][:tags])
      assert_equal([@posts[0].id, @posts[1].id], ids(drawn[:minis][0][:slides]))
      assert_equal({ name: "rain", category: "general" }, drawn[:minis][0][:tag])
      assert_equal([@posts.last.id], ids(drawn[:minis][1][:slides]))
      assert_nil(drawn[:minis][2][:tag])
      assert_equal([], drawn[:minis][2][:slides])
      assert_equal(0, drawn[:locked_count])
      assert_equal([], drawn[:owner_notices])
      assert_equal("/posts/#{@posts[0].id}", drawn[:hero][:slides].first[:url])
    end

    should "fill in the defaults for everything the creator has not set" do
      config = layout.config

      assert_equal("", config["headline"])
      assert_equal({ "post_id" => nil, "y" => 50 }, config["banner"])
      assert_equal({ "blur" => 18, "dim" => 45, "parallax" => 40 }, config["depth"])
      assert_equal({ "tags" => %w[night wren ivo], "effect" => "glide", "dir" => "left", "hold" => 5, "cells" => 5 }, config["hero"])
      assert_equal([{ "tag" => "rain", "effect" => "slide", "dir" => "left", "hold" => 4 },
                    { "tag" => "snow", "effect" => "slide", "dir" => "left", "hold" => 4 },
                    { "tag" => "", "effect" => "slide", "dir" => "left", "hold" => 4 }], config["minis"])
    end

    should "leave out what the viewer may not see, and keep it for a viewer who may" do
      @posts[2].update_columns(is_banned: true) # rubocop:disable Rails/SkipsModelValidations

      assert_not_includes(ids(layout.draw(User.anonymous)[:hero][:slides]), @posts[2].id)
      assert_includes(ids(layout.draw(@admin)[:hero][:slides]), @posts[2].id)
    end

    should "drop a chosen post that is no longer eligible or no longer fits, and tell the owner" do
      CreatorPostAudience.set!(@posts[0], gallery: @gallery, audience: "private", by: @maple)
      @posts[1].update!(tag_string: "neon wren rain")

      drawn = layout.draw(@admin)

      assert_equal(@posts.drop(2).map(&:id), ids(drawn[:hero][:slides]))
      assert_includes(drawn[:owner_notices], "Post ##{@posts[0].id} cannot be chosen: its audience is private. Make it public on Who sees your posts, or take it off.")
      assert_includes(drawn[:owner_notices], "Post ##{@posts[1].id} does not carry night. Take it off the band or change the band's tags.")
    end

    should "draw a legacy gallery's hero rows without a rule, and tell the owner to add tags" do
      # Before the rebuild every row was a hero row, and nothing was set.
      @gallery.creator_gallery_posts.where.not(band: "hero").delete_all
      @gallery.update!(settings: {})

      drawn = layout.draw(@admin)

      assert_equal(@posts.map(&:id), ids(drawn[:hero][:slides]))
      assert_equal(["This gallery has no hero tags yet. Open Edit Gallery, add tags to the hero band and Save."], drawn[:owner_notices])
    end

    # A band tag is a name like any other: one hidden from the viewer is not
    # shown them, as a pill, a character tab or a miniband's label.
    should "leave out a band tag the viewer may not see, and keep it for a viewer who may" do
      Danbooru.config.stubs(:restricted_tags).returns(%w[ivo snow])

      anonymous = layout.draw(User.anonymous)
      assert_equal(%w[night wren], anonymous[:hero][:tags].pluck(:name))
      assert_nil(anonymous[:minis][1][:tag])
      admin = layout.draw(@admin)
      assert_equal(%w[night wren ivo], admin[:hero][:tags].pluck(:name))
      assert_equal("snow", admin[:minis][1][:tag][:name])
    end

    should "draw the banner only for a viewer who may see it" do
      @gallery.update!(settings: @gallery.settings.merge("banner" => { "post_id" => @posts[2].id, "y" => 30 }))

      assert_equal(@posts[2].id, layout.draw(User.anonymous)[:banner][:id])
      @posts[2].update_columns(is_banned: true) # rubocop:disable Rails/SkipsModelValidations
      assert_nil(layout.draw(User.anonymous)[:banner])
    end

    # The banner is a choice like a band's posts: one the creator made private,
    # or another creator's, is drawn for no one, however much they may see.
    should "draw no banner that is not a valid choice, for anyone, and tell the owner why" do
      CreatorPostAudience.set!(@posts[2], gallery: @gallery, audience: "private", by: @maple)
      stray = post_with("night neon", creator: "@alice:41chan.net")

      { @posts[2] => "its audience is private. Make it public on Who sees your posts, or take it off.", stray => "it is not one of your posts. Take it off." }.each do |banner, reason|
        @gallery.update!(settings: @gallery.settings.merge("banner" => { "post_id" => banner.id, "y" => 30 }))
        [User.anonymous, @admin].each { |viewer| assert_nil(layout.draw(viewer)[:banner], "banner ##{banner.id} was drawn for #{viewer.name}") }
        assert_includes(layout.draw(@admin)[:owner_notices], "Post ##{banner.id} cannot be chosen: #{reason}")
      end
    end

    # What the landing page's promoted card and row are drawn from: the hero
    # alone, in the creator's order, judged as the page judges it.
    should "give the landing page the hero's posts in order, without one the viewer may not see or that is not a valid choice" do
      @gallery.creator_gallery_posts.find_by!(band: "hero", post: @posts[1]).update!(position: 9)
      @posts[2].update_columns(is_banned: true) # rubocop:disable Rails/SkipsModelValidations
      @posts[4].update!(tag_string: "neon ivo snow")
      CreatorPostAudience.set!(@posts[0], gallery: @gallery, audience: "private", by: @maple)

      assert_equal([@posts[3], @posts[5], @posts[1]].map(&:id), layout.hero_posts(User.anonymous).map(&:id))
      assert_equal([@posts[2], @posts[3], @posts[5], @posts[1]].map(&:id), layout.hero_posts(@admin).map(&:id))
    end

    # THE GALLERY IS A LIST (operator, 2026-10-18): below full browsing, a
    # page's worth of distinct posts, hero first; the rest only counted.
    should "cut the draw at the browsing tier's page, across the bands, and count the rest" do
      Danbooru.config.stubs(:restricted_browsing_per_page).returns(4)

      drawn = layout.draw(User.anonymous)

      assert_equal(@posts.first(4).map(&:id), ids(drawn[:hero][:slides]))
      assert_equal([@posts[0].id, @posts[1].id], ids(drawn[:minis][0][:slides]))
      assert_equal([], drawn[:minis][1][:slides])
      assert_equal(2, drawn[:locked_count])
      assert_equal(0, layout.draw(@admin)[:locked_count])
    end
  end

  context "Saving" do
    should "write the look and the bands' posts, replacing what was chosen before" do
      choose("hero", [@posts.first])
      choose("mini3", @posts.last(2))

      assert_equal([], layout.save(viewer: @maple, page: { "title" => "Maple", "bio" => "Night shift.", "matrix_contact" => "" }, look: look))

      @gallery.reload
      assert_equal("Maple", @gallery.title)
      assert_equal("Night shift.", @gallery.bio)
      assert_equal("After Hours", @gallery.settings["headline"])
      assert_equal({ "tags" => %w[night wren ivo], "effect" => "depth", "dir" => "right", "hold" => 6, "cells" => 7 }, @gallery.settings["hero"])
      assert_equal({ "tag" => "snow", "effect" => "flip", "dir" => "down", "hold" => 7 }, @gallery.settings["minis"][1])
      rows = @gallery.creator_gallery_posts.group_by(&:band).transform_values { |list| list.map(&:post_id) }
      assert_equal({ "hero" => @posts.map(&:id), "mini1" => @posts.first(3).map(&:id), "mini2" => @posts.last(3).map(&:id), "mini3" => [@posts.first.id] }, rows)
      assert_equal(@posts.first.id, layout.draw(@admin)[:banner][:id])
    end

    should "write nothing and name every problem with its remedy" do
      choose("hero", [@posts.first])
      private_post = @posts[4]
      CreatorPostAudience.set!(private_post, gallery: @gallery, audience: "private", by: @maple)
      stray = post_with("night neon wren", creator: "@alice:41chan.net")
      FourierTagSource.create!(post: @posts[0], tag: "secret_sauce", source: FourierTagSource::CREATOR, status: FourierTagSource::APPROVED, public: false)
      spoiled = look(
        "hero" => hero("tags" => %w[night wren ivo nosuchtag secret_sauce], "posts" => [@posts[0].id, @posts[1].id, private_post.id, stray.id]),
        "minis" => [
          { "tag" => "", "effect" => "slide", "dir" => "left", "hold" => 4, "posts" => [] },
          { "tag" => "snow", "effect" => "spin", "dir" => "left", "hold" => 30, "posts" => [] },
          { "tag" => "night", "effect" => "slide", "dir" => "left", "hold" => 4, "posts" => @posts.map(&:id) + [@posts[0].id] },
        ],
      )

      problems = as_matrix { layout.save(viewer: @maple, page: { "title" => "x" * 121 }, look: spoiled) }

      assert_equal([
        "nosuchtag is not a tag on this booru. Pick tags from the list.",
        "secret_sauce is private to you. Pick a public tag.",
        "The hero band holds 4 of the 5 posts it needs. Open Posts on the band and pick more.",
        "ivo is on none of the band's posts. Pick a post that has it, or take the tag off.",
        "Post ##{private_post.id} cannot be chosen: its audience is private. Make it public on Who sees your posts, or take it off.",
        "Post ##{stray.id} cannot be chosen: it is not one of your posts. Take it off.",
        "Miniband 1 has no tag. Pick one on the miniband.",
        "Miniband 2's effect must be one of slide, fade, drift, flip or depth.",
        "Miniband 2's hold must be a whole number of seconds from 2 to 12.",
        "Miniband 2 has no posts. Open Posts on it and pick at least one.",
        "Miniband 3 holds 7 posts; 6 is the most.",
        "Post ##{@posts[0].id} is on miniband 3 twice. Take one off.",
        "Title is too long (maximum is 120 characters)",
      ], problems)
      @gallery.reload
      assert_equal({}, @gallery.settings)
      assert_equal("", @gallery.title)
      assert_equal([["hero", @posts.first.id]], @gallery.creator_gallery_posts.pluck(:band, :post_id))
    end

    should "refuse a hero band with no tags, too many posts, too many characters or a post that does not fit" do
      extra = Array.new(19) { post_with("night neon wren") }
      chars = Array.new(5) { |i| create(:tag, name: "char#{i}", category: Tag.categories.character).name }

      assert_equal(["The hero band has no tags. Add one with + Tag on the band."],
                   layout.save(viewer: @maple, page: {}, look: look("hero" => hero("tags" => []))))
      assert_equal(["The hero band holds 25 posts; 24 is the most. Take some off."],
                   layout.save(viewer: @maple, page: {}, look: look("hero" => hero("posts" => (@posts + extra).map(&:id)))))
      assert_includes(layout.save(viewer: @maple, page: {}, look: look("hero" => hero("tags" => %w[night wren ivo] + chars))),
                      "The hero band has more than 5 character tags. Take one off.")
      assert_equal(@posts.first(3).map { |post| "Post ##{post.id} does not carry any of ivo. Take it off the band or change the band's tags." },
                   layout.save(viewer: @maple, page: {}, look: look("hero" => hero("tags" => %w[night ivo]))))
      assert_equal(["Post ##{@posts[0].id} does not carry snow. Take it off miniband 1 or change its tag."],
                   layout.save(viewer: @maple, page: {}, look: look("minis" => look["minis"].each_with_index.map { |mini, i| (i == 0) ? mini.merge("tag" => "snow", "posts" => [@posts[0].id]) : mini })))
    end

    should "name the allowed values of every setting it refuses" do
      problems = layout.save(viewer: @maple, page: {}, look: look(
        "headline" => "x" * 121,
        "banner" => { "post_id" => nil, "y" => 101 },
        "depth" => { "blur" => 49, "dim" => -1, "parallax" => "far" },
        "hero" => hero("effect" => "spin", "dir" => "up", "hold" => 1, "cells" => 4),
        "layout" => "5",
      ))

      assert_equal([
        "The headline is 121 characters; 120 is the most. Shorten it.",
        "The banner's position must be a whole number from 0 to 100.",
        "The depth's blur must be a whole number from 0 to 48.",
        "The depth's dim must be a whole number from 0 to 85.",
        "The depth's parallax must be a whole number from 0 to 100.",
        "The hero band's effect must be one of glide, depth or float.",
        "The hero band's direction must be one of left or right.",
        "The hero band's hold must be a whole number of seconds from 2 to 12.",
        "The hero band's cells must be one of 3, 5, 7 or 9.",
        "The layout must be one of 2-3, 3-2, 1-2, 2-2, 1-3 or 4.",
      ], problems)
    end

    # A tag hidden from the curator does not exist for them: Save answers it
    # as it answers a name the booru does not have, so it cannot be asked.
    should "answer a band tag hidden from the curator as one the booru does not have" do
      Danbooru.config.stubs(:restricted_tags).returns(%w[ivo])

      assert_includes(layout.save(viewer: User.anonymous, page: {}, look: look), "ivo is not a tag on this booru. Pick tags from the list.")
      assert_equal([], layout.save(viewer: @admin, page: {}, look: look))
    end

    # A post hidden from the curator does not exist for them either: Save
    # answers its id as it answers an id with no post.
    should "answer a post hidden from the curator as no such post" do
      alice = CreatorGallery.create!(slug: "alice", matrix_id: "@alice:41chan.net", user: create(:user))
      veiled = post_with("night neon wren", creator: "@alice:41chan.net")
      CreatorPostAudience.set!(veiled, gallery: alice, audience: "private", by: alice.user)

      assert_includes(layout.save(viewer: @maple, page: {}, look: look("hero" => hero("posts" => [*@posts.first(5).map(&:id), veiled.id]))),
                      "Post ##{veiled.id} cannot be chosen: there is no such post. Take it off.")
      assert_equal("Post ##{veiled.id} cannot be chosen: there is no such post. Take it off.", layout.add(veiled, "hero", @maple))
    end

    # set! keeps the row when a post goes back to the default, as "inherit":
    # the default decides it, and the refusal names the default.
    should "name the default as the audience of a post set back to inherit" do
      @gallery.set_default_audience!("private", by: @maple)
      CreatorPostAudience.set!(@posts[0], gallery: @gallery, audience: "public", by: @maple)
      CreatorPostAudience.set!(@posts[0], gallery: @gallery, audience: "inherit", by: @maple)

      assert_includes(layout.save(viewer: @maple, page: {}, look: look),
                      "Post ##{@posts[0].id} cannot be chosen: its audience is private. Make it public on Who sees your posts, or take it off.")
    end

    should "call a tag private to the curator when only their private posts carry it" do
      CreatorPostAudience.set!(@posts[0], gallery: @gallery, audience: "private", by: @maple)
      FourierTagSource.create!(post: @posts[0], tag: "secret_sauce", source: FourierTagSource::CREATOR, status: FourierTagSource::APPROVED, public: false)

      assert_includes(as_matrix { layout.save(viewer: @maple, page: {}, look: look("hero" => hero("tags" => %w[night wren ivo secret_sauce]))) },
                      "secret_sauce is private to you. Pick a public tag.")
    end

    # "Private to you" says the tag exists: only for a viewer who may read the
    # post's creator-only data (FourierCreatorPrivacy) -- not an admin editing
    # the gallery, not the owner over a post someone else is the creator of.
    should "answer a private tag as no tag to a viewer who may not read it" do
      FourierTagSource.create!(post: @posts[0], tag: "secret_sauce", source: FourierTagSource::CREATOR, status: FourierTagSource::APPROVED, public: false)
      spiced = look("hero" => hero("tags" => %w[night wren ivo secret_sauce]))
      unknown = "secret_sauce is not a tag on this booru. Pick tags from the list."

      assert_includes(layout.save(viewer: @admin, page: {}, look: spiced), unknown)
      assert_includes(as_matrix("@alice:41chan.net") { layout.save(viewer: @maple, page: {}, look: spiced) }, unknown)
      assert_includes(as_matrix { layout.save(viewer: @maple, page: {}, look: spiced) }, "secret_sauce is private to you. Pick a public tag.")
    end

    # An eligible post the curator may not see is no post to them either, or
    # Save would tell them it is the creator's, public and live.
    should "answer an eligible post hidden from the curator as no such post" do
      Danbooru.config.stubs(:restricted_tags).returns(%w[snow])
      gone = "Post ##{@posts[5].id} cannot be chosen: there is no such post. Take it off."

      assert_includes(layout.save(viewer: User.anonymous, page: {}, look: look), gone)
      assert_equal(gone, layout.add(@posts[5], "mini2", User.anonymous))
      assert_not_includes(layout.save(viewer: @admin, page: {}, look: look), gone)
    end

    should "refuse a banner the creator made private or that is not theirs, and write nothing" do
      CreatorPostAudience.set!(@posts[2], gallery: @gallery, audience: "private", by: @maple)
      stray = post_with("night neon", creator: "@alice:41chan.net")
      page = { "title" => "Maple", "bio" => "", "matrix_contact" => "" }

      { @posts[2] => "its audience is private. Make it public on Who sees your posts, or take it off.", stray => "it is not one of your posts. Take it off." }.each do |banner, reason|
        problems = layout.save(viewer: @admin, page: page, look: look("banner" => { "post_id" => banner.id, "y" => 40 }))

        assert_includes(problems, "Post ##{banner.id} cannot be chosen: #{reason}")
        assert_nil(@gallery.reload.settings.dig("banner", "post_id"))
      end
    end

    should "want a miniband for every slot of the layout" do
      assert_equal(["The layout 2-3 has 5 minibands; 3 were sent."], layout.save(viewer: @maple, page: {}, look: look("layout" => "2-3")))
    end
  end

  context "The avatar" do
    setup do
      Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
      Danbooru.config.stubs(:fourier_media_origin).returns("https://chat.example")
      Danbooru.config.stubs(:fourier_matrix_profile_token).returns("syt_reader")
    end

    # The homeserver reads profiles only for a signed-in account
    # (require_auth_for_profile_requests, 2026-10-02), so the booru asks as one.
    should "read the creator's Matrix profile as the configured reader, and give members the thumbnail" do
      HTTP::Client.any_instance.expects(:perform).once
                  .with { |request, _| request.uri.to_s == "https://chat.example/_matrix/client/v3/profile/@maple:41chan.net" && request.headers["Authorization"] == "Bearer syt_reader" }
                  .returns(profile({ displayname: "Maple", avatar_url: "mxc://41chan.net/AbC_12-x" }))

      member = layout.avatar(@maple)
      assert_equal({ name: "Maple", mxc: "mxc://41chan.net/AbC_12-x", problem: nil,
                     url: "https://chat.example/_matrix/client/v1/media/thumbnail/41chan.net/AbC_12-x?width=96&height=96&method=crop" }, member)
      # Cached: the second read asks nobody, and a signed-out viewer gets the name alone.
      CurrentUser.set(user: User.anonymous, request: ActionDispatch::TestRequest.create) do
        assert_equal({ name: "Maple", mxc: "mxc://41chan.net/AbC_12-x", problem: nil, url: nil }, layout.avatar(User.anonymous))
      end
    end

    should "say what went wrong and how to fix it when the profile cannot be read" do
      Danbooru::Http.any_instance.stubs(:get).returns(profile({ errcode: "M_UNKNOWN" }, status: 502))

      avatar = layout.avatar(@maple)
      assert_nil(avatar[:url])
      assert_match(/HTTP 502/, avatar[:problem])
      assert_match(/fourier_media_origin/, avatar[:problem])
    end

    should "name the reader's token, not the origin, when the homeserver refuses it" do
      Danbooru::Http.any_instance.stubs(:get).returns(profile({ errcode: "M_UNKNOWN_TOKEN" }, status: 401))

      problem = layout.avatar(@maple)[:problem]
      assert_match(/HTTP 401/, problem)
      assert_match(/DANBOORU_FOURIER_MATRIX_PROFILE_TOKEN/, problem)
      assert_no_match(/fourier_media_origin/, problem)
      assert_no_match(/syt_reader/, problem)
    end

    should "ask nobody, and say what to set, when no reader's token is configured" do
      Danbooru.config.stubs(:fourier_matrix_profile_token).returns(nil)
      Danbooru::Http.any_instance.expects(:get).never

      assert_equal({ name: nil, mxc: nil, url: nil, problem: CreatorGalleryLayout::NO_PROFILE_TOKEN }, layout.avatar(@maple))
    end

    should "refuse an avatar_url that is not an mxc URI" do
      Danbooru::Http.any_instance.stubs(:get).returns(profile({ displayname: "Maple", avatar_url: "https://evil.example/a.png" }))

      assert_equal({ name: "Maple", mxc: nil, url: nil, problem: nil }, layout.avatar(@maple))
    end

    should "say so when no media origin is configured" do
      Danbooru.config.stubs(:fourier_media_origin).returns(nil)

      assert_equal({ name: nil, mxc: nil, url: nil, problem: "fourier_media_origin is not configured; set it in danbooru_local_config.rb" }, layout.avatar(@maple))
    end
  end
end
