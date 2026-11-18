# frozen_string_literal: true

require "test_helper"

# Modulation's wiki page: upstream's wiki_pages/show body drawn as a subject
# heading, the article in a panel and the tag's posts as a strip. Every
# condition is upstream's; these cases hold the component to each of them.
class ModulationWikiComponentTest < ViewComponent::TestCase
  def draw(wiki_page, user: @member)
    CurrentUser.scoped(user) do
      render_inline(ModulationWikiComponent.new(wiki_page: wiki_page, viewer: user))
    end
  end

  setup do
    @member = create(:user)
    @posts = as(@member) { create_list(:post, 3, tag_string: "mwcomp") }
    @wiki = as(@member) { create(:wiki_page, title: "mwcomp", body: "mwcomp article text") }
  end

  should "draw the title as the subject heading, keeping its id, and the body as prose" do
    draw(@wiki)

    assert_css("h1#wiki-page-title.mod-subject a[href='/posts?tags=mwcomp']", text: /mwcomp/)
    assert_css("#wiki-page-body.prose", text: /mwcomp article text/)
    assert_no_text("This wiki page does not exist")
  end

  # Upstream wiki_pages/_posts.html.erb: the tag's posts, as the gallery's cards.
  should "draw the tag's posts as a strip of the gallery's cards" do
    draw(@wiki)

    assert_css("section.modstrip > h2.modstrip-title > a[href='/posts?tags=mwcomp']", text: "Posts")
    @posts.each { |post| assert_css("a.modgal-card[data-id='#{post.id}']") }
    assert_no_css(".modgal")
  end

  should "draw no strip when the page has no tag" do
    page = as(@member) { create(:wiki_page, title: "mwcomp_notag", body: "x") }
    draw(page)

    assert_no_css(".modstrip")
    assert_no_text("No posts found.")
  end

  should "draw no strip when the tag is empty" do
    create(:tag, name: "mwcomp_empty", post_count: 0)
    page = as(@member) { create(:wiki_page, title: "mwcomp_empty", body: "x") }
    draw(page)

    assert_no_css(".modstrip")
  end

  should "say so when the tag has posts and none are drawn" do
    create(:tag, name: "mwcomp_ghost", post_count: 5)
    page = as(@member) { create(:wiki_page, title: "mwcomp_ghost", body: "x") }
    draw(page)

    assert_css("section.modstrip h2.modstrip-title a[href='/posts?tags=mwcomp_ghost']", text: "Posts")
    assert_css("section.modstrip p.modstrip-empty", text: "No posts found.")
    assert_no_css("a.modgal-card")
  end

  should "draw the locked and deleted states" do
    @wiki.update_columns(is_locked: true, is_deleted: true) # rubocop:disable Rails/SkipsModelValidations -- a state, not an edit under test
    draw(@wiki.reload)

    assert_css("h1#wiki-page-title", text: /locked/)
    assert_css("h1#wiki-page-title", text: /deleted/)
  end

  should "draw neither state on a plain page" do
    draw(@wiki)

    assert_no_css("h1#wiki-page-title", text: /locked/)
    assert_no_css("h1#wiki-page-title", text: /deleted/)
  end

  # Upstream wiki_pages/show.html.erb:32-40, the Create link under
  # policy(@wiki_page).create? (show.html.erb:34).
  context "a page that does not exist" do
    setup do
      @missing = WikiPage.new(title: "mwcomp_nonesuch")
    end

    should "offer a member the Create link" do
      draw(@missing)

      assert_css("#wiki-page-body.prose", text: /This wiki page does not exist/)
      assert_css("#wiki-page-body a[rel='nofollow']", text: "Create new wiki page")
    end

    should "not offer the Create link to anonymous" do
      draw(@missing, user: User.anonymous)

      assert_css("#wiki-page-body.prose", text: /This wiki page does not exist/)
      assert_no_text("Create new wiki page")
    end

    should "not offer the Create link to a restricted user" do
      draw(@missing, user: create(:restricted_user))

      assert_css("#wiki-page-body.prose", text: /This wiki page does not exist/)
      assert_no_text("Create new wiki page")
    end
  end

  # Upstream wiki_pages/show.html.erb:42.
  should "link to the artist when the page has one that is not deleted" do
    # setup's posts made the tag general; an artist entry needs an artist tag.
    Tag.find_by_name("mwcomp").update!(category: Tag.categories.artist, updater: @member)
    create(:artist, name: "mwcomp")
    draw(@wiki)

    assert_css(".modwiki-notes a.mod-pill", text: "View artist")
  end

  should "not link to a deleted artist" do
    create(:artist, name: "mwcomp", is_deleted: true)
    draw(@wiki)

    assert_no_text("View artist")
  end

  # Upstream wiki_pages/show.html.erb:48.
  should "draw the deprecation line for a deprecated tag" do
    Tag.find_by_name("mwcomp").update_columns(is_deprecated: true) # rubocop:disable Rails/SkipsModelValidations -- a state, not an edit under test
    draw(@wiki.reload)

    assert_css(".modwiki-notes .fineprint", text: /deprecated/)
  end

  should "draw no notes block when no note applies" do
    draw(@wiki)

    assert_no_css(".modwiki-notes")
  end

  # Upstream wiki_pages/show.html.erb:27.
  should "draw the other names panel only when there are some" do
    @wiki.update_columns(other_names: ["mwcomp_alt"]) # rubocop:disable Rails/SkipsModelValidations -- a state, not an edit under test
    draw(@wiki.reload)

    assert_css("section.mod-panel.modwiki-names", text: /mwcomp_alt/)
  end

  should "draw no other names panel without any" do
    draw(@wiki)

    assert_no_css(".modwiki-names")
  end
end
