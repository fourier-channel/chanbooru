# frozen_string_literal: true

require "test_helper"

# Modulation's artist page body: every branch of upstream's
# app/views/artists/show.html.erb and artists/_summary.html.erb, drawn as
# panels, with the artist's posts as a strip of the gallery's cards.
class ModulationArtistComponentTest < ViewComponent::TestCase
  def draw(artist, user: @member)
    CurrentUser.scoped(user) do
      render_inline(ModulationArtistComponent.new(artist: artist, viewer: user))
    end
  end

  setup do
    @member = create(:user)
  end

  context "the takedown gate" do
    should "draw only the takedown line for a banned artist a viewer may not see" do
      artist = as(@member) { create(:artist, name: "macomp_banned", is_banned: true) }
      draw(artist, user: User.anonymous)

      assert_css(".mod-artist-takedown", text: "This page has been removed because of a takedown request.")
      assert_no_css(".mod-subject")
      assert_no_css(".artist-wiki")
      assert_no_css("#view-artist-link")
    end

    should "draw a banned or deleted artist with its badges for a viewer who may see it" do
      artist = as(@member) { create(:artist, name: "macomp_flagged", is_banned: true, is_deleted: true) }
      draw(artist)

      assert_no_css(".mod-artist-takedown")
      assert_css("h1.mod-subject .mod-pill--subject", text: "macomp flagged")
      assert_css(".mod-subject .mod-badge", text: "BANNED")
      assert_css(".mod-subject .mod-badge", text: "DELETED")
    end
  end

  context "a new entry (show_or_new)" do
    should "say it does not exist and link to create it, with no edit links" do
      draw(Artist.new(name: "macomp_nobody"))

      assert_css(".mod-artist-missing", text: "This artist entry does not exist.")
      assert_css(".mod-artist-missing a[rel='nofollow'][href*='artist%5Bname%5D=macomp_nobody']", text: "Create new artist entry")
      assert_css("h1.mod-subject", text: "macomp nobody")
      assert_no_css("#view-artist-link")
      assert_no_css("#view-wiki-link")
      assert_no_css(".modstrip")
    end
  end

  context "an existing entry" do
    should "draw its active wiki and both edit links" do
      artist = as(@member) { create(:artist, name: "macomp_wiki") }
      as(@member) { create(:wiki_page, title: "macomp_wiki", body: "macomp wiki body") }
      draw(artist.reload)

      assert_css(".mod-artist-wiki-panel .artist-wiki.prose", count: 1, text: "macomp wiki body")
      assert_css(".mod-artist-body.mod-artist-body--wiki")
      assert_css("#view-wiki-link", text: "Edit wiki")
      assert_css("#view-artist-link", text: "Edit artist")
    end

    should "not draw a deleted wiki, nor its edit link" do
      artist = as(@member) { create(:artist, name: "macomp_nowiki") }
      as(@member) { create(:wiki_page, title: "macomp_nowiki", is_deleted: true) }
      draw(artist.reload)

      assert_css(".artist-wiki", count: 0)
      assert_no_css("#view-wiki-link")
      assert_css("#view-artist-link", text: "Edit artist")
    end

    should "draw its URLs, an inactive one dotted, and its other names as pills" do
      artist = as(@member) do
        create(:artist, name: "macomp_urls", other_names: ["macomp_alias"], url_string: "http://example.com/macomp_live\n-http://example.com/macomp_dead")
      end
      draw(artist.reload)

      assert_css(".mod-artist-urls li", count: 2)
      assert_css(".mod-artist-urls a.inactive-artist-url", text: "http://example.com/macomp_dead")
      assert_css(".mod-artist-urls a:not(.inactive-artist-url)", text: "http://example.com/macomp_live")
      assert_css(".mod-artist-names dd a.artist-other-name.mod-pill[rel='nofollow']", text: "macomp_alias")
    end
  end

  context "the creator release box" do
    setup do
      @artist = as(@member) { create(:artist, name: "macomp_creator") }
      entry = CreatorPrefixes::Entry.new(prefix: "macomp_", visible_to: "admins")
      CreatorPrefixes.stubs(:lookup).with("macomp_creator").returns(entry)
    end

    should "draw for a viewer who may set the release" do
      CreatorTagRelease.stubs(:may_set?).with(@member, "macomp_creator").returns(true)
      draw(@artist)

      assert_css(".creator-release-box input[type=submit][value='Release my posts']")
      assert_css(".creator-release-box input[type=hidden][name=tag_name][value='macomp_creator']", visible: :all)
      assert_css(".creator-release-box input[type=hidden][name=released][value='true']", visible: :all)
    end

    should "not draw for a viewer who may not" do
      CreatorTagRelease.stubs(:may_set?).with(@member, "macomp_creator").returns(false)
      draw(@artist)

      assert_no_css(".creator-release-box")
    end
  end

  context "the artist's posts" do
    should "draw as a strip of cards, never the gallery's window" do
      # The artist first: its entry makes the tag an artist tag, and an entry
      # can no longer be made for a tag the posts already made general.
      artist = as(@member) { create(:artist, name: "macomp_poster") }
      posts = as(@member) { create_list(:post, 2, tag_string: "macomp_poster") }
      draw(artist.reload)

      assert_css("section.modstrip h2.modstrip-title a[href*='tags=macomp_poster']", text: "Posts")
      posts.each { |post| assert_css("section.modstrip a.modgal-card[data-id='#{post.id}']") }
      assert_no_css(".modgal")
      assert_no_css(".modgal-grid")
    end

    should "draw no posts section when the tag has no posts" do
      artist = as(@member) { create(:artist, name: "macomp_empty") }
      draw(artist.reload)

      assert_no_css(".modstrip")
      assert_no_css(".modstrip-empty")
      assert_no_text("No posts found.")
    end

    # Upstream draws its "Posts" heading over an empty gallery, which says
    # so: the tag counts posts, and none is drawn for this viewer.
    should "say so under its heading when the tag has posts and none are drawn" do
      create(:tag, name: "macomp_ghost", category: Tag.categories.artist, post_count: 5)
      artist = as(@member) { create(:artist, name: "macomp_ghost") }
      draw(artist.reload)

      assert_css("section.modstrip h2.modstrip-title a[href*='tags=macomp_ghost']", text: "Posts")
      assert_css("section.modstrip p.modstrip-empty", text: "No posts found.")
      assert_no_css("a.modgal-card")
    end
  end
end
