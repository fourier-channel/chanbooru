require "test_helper"

# The front page is the shop window, so re-aiming it is an admin act.
#
# WHICH FORM DOES WHAT, since 2026-09-17. The console carries two: the
# carousel-wide LandingSetting (the slide speed), and the Categories form, one
# fieldset per LandingCategory row -- which is where the "new" row's board,
# heading and fresh-only toggle live, because that table is what
# LandingShowcase reads (8b8f06cee). This file used to re-aim the front page
# through LandingSetting and read the result from LandingShowcase.categories;
# that class method went with 8b8f06cee and so did LandingSetting's say over
# the row, while the console went on offering the dead fields. The re-aim is
# tested here through the form that actually does it, through to the showcase.
class Admin::LandingSettingsControllerTest < ActionDispatch::IntegrationTest
  TRASH = "https://boards.4chan.org/trash/thread/1#p2"

  context "the landing setting panel" do
    setup do
      @admin = create(:admin_user)
      @user = create(:user)
    end

    should "not be reachable by an ordinary user" do
      get_auth admin_landing_setting_path, @user
      assert_response 403
    end

    should "not be reachable anonymously" do
      # A flat refusal rather than a redirect to a login: this fork answers 403
      # here, which is the better answer -- an admin page should not advertise
      # itself to a stranger by inviting them to sign in.
      get admin_landing_setting_path
      assert_response 403
    end

    should "render for an admin" do
      get_auth admin_landing_setting_path, @admin
      assert_response :success
    end

    should "offer one control for the new row's target, not two" do
      # The carousel-wide form carried a heading, a board and a fresh-only
      # toggle for a week after nothing read them, and saving them said "The
      # front page now shows ..." while it did not.
      get_auth admin_landing_setting_path, @admin
      assert_response :success
      %w[board label fresh_only].each do |attr|
        assert_select "[name='landing_setting[#{attr}]']", count: 0
      end
      assert_select "[name='landing_categories[new][board]']", count: 1
      assert_select "[name='landing_setting[advance_ms]']", count: 1
    end

    should "change the slide speed" do
      put_auth admin_landing_setting_path, @admin, params: { landing_setting: { advance_ms: "9000" }}
      assert_redirected_to admin_landing_setting_path
      assert_equal 9000, LandingSetting.current.advance_ms
    end

    should "change what the front page shows" do
      binned = as(@user) { create(:post, source: TRASH) }

      login_as(@admin)
      patch categories_admin_landing_setting_path, params: {
        landing_categories: { new: { enabled: "1", label: "From the bin", board: "trash", fresh_only: "0", ordering: "new" }},
      }

      assert_redirected_to admin_landing_setting_path
      assert_equal ["source:https://boards.4chan.org/trash/*"], LandingCategory.find_by!(key: "new").queries
      row = LandingShowcase.new(viewer: User.anonymous).categories.find { |c| c[:key] == "new" }
      assert_not_nil row, "the new row came back empty, so it did not search /trash/"
      assert_equal "From the bin", row[:label]
      assert_includes row[:slides].pluck(:id), binned.id
    end

    should "show the blog row with the address it reads, and no search controls" do
      get_auth admin_landing_setting_path, @admin

      assert_select "fieldset[data-key=blog]", 1
      assert_select "[name='landing_categories[blog][enabled]'][type=checkbox]", 1
      assert_select "[name='landing_categories[blog][label]']", 1
      assert_select "[name='landing_categories[blog][ordering]']", 0
      assert_select "[name='landing_categories[blog][tags_string]']", 0
      assert_select "fieldset[data-key=blog] code", text: LandingBlogCache.index_url
      assert_select "fieldset[data-key=blog] [data-blog-status=never]", 1
    end

    should "say what the last read of the blog found" do
      seed_blog

      get_auth admin_landing_setting_path, @admin

      assert_select "fieldset[data-key=blog] [data-blog-status=ok]", text: /2 posts/
    end

    should "say when the last read of the blog failed, and what is still shown" do
      seed_blog(now: 1.hour.ago)
      stub_blog_index("oops", status: 500, content_type: "text/plain")
      assert_raises(LandingBlogCache::Error) { LandingBlogCache.refresh! }

      get_auth admin_landing_setting_path, @admin

      assert_select "fieldset[data-key=blog] [data-blog-status=failed]", text: /500/
      assert_select "fieldset[data-key=blog] [data-blog-status=failed]", text: /still showing 2 posts/
    end

    # An unmeasured read must not render as a healthy one: an ok status that
    # is far older than the refresh clock means nothing has tried since.
    should "say when the blog has not been read for longer than the clock allows" do
      seed_blog(now: 1.hour.ago)

      get_auth admin_landing_setting_path, @admin

      assert_select "fieldset[data-key=blog] [data-blog-status=stalled]", 1
    end

    # It ships off; "Show this row" is the switch, as for every row.
    should "turn the blog row on, and off again" do
      seed_blog
      login_as(@admin)

      patch categories_admin_landing_setting_path, params: { landing_categories: { blog: { enabled: "1", label: "Blog" }}}
      assert_redirected_to admin_landing_setting_path
      assert LandingCategory.find_by!(key: "blog").enabled?
      assert_not_nil LandingShowcase.new(viewer: User.anonymous).categories.find { it[:key] == "blog" }

      patch categories_admin_landing_setting_path, params: { landing_categories: { blog: { enabled: "0", label: "Blog" }}}
      assert_not LandingCategory.find_by!(key: "blog").enabled?
      assert_nil LandingShowcase.new(viewer: User.anonymous).categories.find { it[:key] == "blog" }
    end

    should "draw a row's creators as their artist pills, lit while active, and name a tag that does not exist" do
      create(:artist_tag, name: "lit_artist")
      create(:artist_tag, name: "quiet_artist")
      as(@user) { create(:post, tag_string: "lit_artist") }
      travel_to(1.day.ago) { as(@user) { create(:post, tag_string: "quiet_artist") } }
      LandingCategory.create!(LandingCategory::DEFAULTS.find { it[:key] == "featured" }.merge(tags: %w[lit_artist quiet_artist no_such_artist]))

      get_auth admin_landing_setting_path, @admin

      featured = "fieldset[data-key=featured]"
      assert_select "#{featured} input[type=hidden][name='landing_categories[featured][tags_string]'][value='lit_artist quiet_artist no_such_artist']", 1
      assert_select "#{featured} input[type=text][name='landing_categories[featured][tags_string]']", 0
      assert_select "#{featured} .mod-pill--cat-artist.is-live[data-tag=lit_artist] .mod-pill-dot", 1
      assert_select "#{featured} .mod-pill--cat-artist[data-tag=quiet_artist]:not(.is-live)", 1
      assert_select "#{featured} .mod-pill--pending", text: "no such artist"
      assert_select "#{featured} .landing-creators-missing", text: /no_such_artist/
    end

    should "refuse a board slug that is really a search, and say so" do
      login_as(@admin)
      patch categories_admin_landing_setting_path, params: {
        landing_categories: { new: { enabled: "1", label: "Sneaky", board: "b -no_train", fresh_only: "1", ordering: "new" }},
      }

      assert_response :unprocessable_entity
      assert_match(/is a board slug like/, response.body)
      assert_not_equal "b -no_train", LandingCategory.find_by(key: "new")&.board
    end
  end

  # THE ERROR PAGE'S PICTURES (operator, 2026-10-11): a small section on this
  # console, saved by the same update action as the slide speed (no new
  # routes). Each listed id says whether the error page can draw it -- by the
  # hero band's own anonymous rule -- and a post it cannot draw is never drawn
  # here either: no thumbnail, no media address, not even for an admin.
  context "the error page's pictures" do
    setup do
      CreatorPrefixes.reset!
      @admin = create(:admin_user)
      @uploader = create(:builder_user) # no upload limit: these tests post many
      @ok = as(@uploader) { create(:post, uploader: @uploader, tag_string: "ep_landscape") }
    end

    teardown do
      CreatorPrefixes.reset!
    end

    should "save the ids from the same update action, and say what was saved" do
      other = as(@uploader) { create(:post, uploader: @uploader, tag_string: "ep_landscape") }
      put_auth admin_landing_setting_path, @admin, params: { landing_setting: { error_page_post_ids_text: "#{@ok.id},\n#{other.id} #{@ok.id}" }}

      assert_redirected_to admin_landing_setting_path
      assert_equal [@ok.id, other.id], LandingSetting.current.error_page_post_ids
      assert_match(/2 posts/, flash[:notice])
      assert_match(/2 shown/, flash[:notice])
    end

    should "leave the slide speed alone when only the pictures are saved, and the reverse" do
      LandingSetting.current.update!(advance_ms: 8000, error_page_post_ids: [@ok.id])
      put_auth admin_landing_setting_path, @admin, params: { landing_setting: { error_page_post_ids_text: "" }}
      assert_equal 8000, LandingSetting.current.advance_ms
      assert_equal [], LandingSetting.current.error_page_post_ids

      LandingSetting.current.update!(error_page_post_ids: [@ok.id])
      put_auth admin_landing_setting_path, @admin, params: { landing_setting: { advance_ms: "9000" }}
      assert_equal [@ok.id], LandingSetting.current.error_page_post_ids
    end

    should "refuse an id that names no post, naming it, and keep what was typed" do
      put_auth admin_landing_setting_path, @admin, params: { landing_setting: { error_page_post_ids_text: "#{@ok.id} 999999991" }}

      assert_response :unprocessable_entity
      assert_match(/#999999991/, response.body)
      assert_select "textarea[name='landing_setting[error_page_post_ids_text]']", text: /999999991/
      assert_equal [], LandingSetting.current.error_page_post_ids
    end

    should "be refused to a user who is not an admin" do
      put_auth admin_landing_setting_path, create(:moderator_user), params: { landing_setting: { error_page_post_ids_text: @ok.id.to_s }}

      assert_response 403
      assert_equal [], LandingSetting.current.error_page_post_ids
    end

    should "say for each id whether it is shown, and draw no picture of one that is skipped" do
      gallery = CreatorGallery.create!(matrix_id: "@hidden:41chan.net", slug: "hidden-console", user: create(:user))
      tier = CreatorGroup.make!(gallery, name: "41chan_hidden_tier_1", tier: 1, by: gallery.user)
      tunnel = create(:builder_user, name: "tunnel")
      hidden = as(tunnel) { create(:post, uploader: tunnel, tag_string: "ep_landscape") }
      FourierPostCreator.create!(post: hidden, mxid: gallery.matrix_id, recorded_by: tunnel.id)
      gallery.set_default_audience!("groups", by: gallery.user, group_ids: [tier.id])
      CreatorVisibility.forget!
      # Its own uploader: a deleted upload counts against its uploader's limit.
      deleter = create(:builder_user)
      deleted = as(deleter) { create(:post, uploader: deleter, tag_string: "ep_landscape") }
      deleted.update!(is_deleted: true)
      jailed = as(@uploader) { create(:post, uploader: @uploader, tag_string: "ep_landscape #{Danbooru.config.troll_jail_tag}") }
      gated = as(@uploader) { create(:post, uploader: @uploader, tag_string: "ep_landscape child") }
      video = as(@uploader) { create(:post, uploader: @uploader, tag_string: "ep_landscape", file_ext: "mp4") }
      setting = LandingSetting.current
      setting.update!(error_page_post_ids: [@ok.id, deleted.id, jailed.id, hidden.id, gated.id, video.id])
      LandingSetting.connection.execute("UPDATE landing_settings SET error_page_post_ids = array_append(error_page_post_ids, 999999994) WHERE id = #{setting.id}")

      get_auth admin_landing_setting_path, @admin
      assert_response :success

      line = ->(id) { "[data-error-page-post='#{id}']" }
      assert_select "#{line[@ok.id]}[data-status=shown]", 1
      assert_select "#{line[@ok.id]} img[src='#{@ok.media_asset.variant(:"180x180").file_url}']", 1
      {
        deleted => /deleted or jailed/,
        jailed => /deleted or jailed/,
        hidden => /hidden by its creator/,
        gated => /gated for signed-out visitors/,
        video => /not an image/,
      }.each do |post, reason|
        assert_select "#{line[post.id]}[data-status=skipped]", { text: reason }, "post ##{post.id}"
        assert_select "#{line[post.id]} img", 0
        assert_select "#{line[post.id]} a", 0
        # No address of its media anywhere on the page: not a thumbnail, not
        # a link, not an attribute.
        assert_no_match(/#{post.md5}/, response.body, "post ##{post.id}'s media is named on the console")
      end
      assert_select "#{line[999_999_994]}[data-status=skipped]", text: /missing/
    end
  end
end
