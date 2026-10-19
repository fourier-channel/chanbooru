require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  context "The application helper" do
    context "format_text method" do
      should "not raise an exception for invalid DText" do
        dtext = "\x00"

        assert_nothing_raised { format_text(dtext) }
        assert_equal("", format_text(dtext))
      end
    end

    # A help wiki is drawn as the viewer: its embeds are theirs to see, and a
    # full account is not held to the page of a viewer below full browsing.
    context "embed_wiki method" do
      should "draw a wiki's embeds as the viewer sees them" do
        Danbooru.config.stubs(:restricted_browsing_per_page).returns(2)
        posts = create_list(:post, 5, rating: "g")
        create(:wiki_page, title: "help:tierembed", body: posts.map { |p| "!post ##{p.id}" }.join("\n\n"))
        drawn = -> { Nokogiri::HTML5.fragment(embed_wiki("help:tierembed")).css("article.dtext-media-embed .media-embed-image img").size }

        CurrentUser.scoped(create(:user)) { assert_equal(5, drawn.call) }
        CurrentUser.scoped(create(:restricted_user)) { assert_equal(2, drawn.call) }
      end
    end

    context "link_to_media_asset method" do
      should "render link" do
        media_asset = create(:media_asset, file_ext: "jpg")
        link = link_to_media_asset(media_asset)
        text = "#{ActiveSupport::NumberHelper.number_to_human_size(media_asset.file_size)} .#{media_asset.file_ext}, " \
               "#{media_asset.image_width}x#{media_asset.image_height}"

        assert_match(/#{Regexp.quote(media_asset_path(media_asset))}/, link)
        assert_match(/#{Regexp.quote(text)}/, link)
      end

      should "render link with duration" do
        media_asset = create(:media_asset, file_ext: "mp4", duration: 30)
        link = link_to_media_asset(media_asset)
        text = "#{ActiveSupport::NumberHelper.number_to_human_size(media_asset.file_size)} .#{media_asset.file_ext}, " \
               "#{media_asset.image_width}x#{media_asset.image_height} " \
               "(#{Danbooru::Helpers.duration_to_hhmmss(media_asset.duration)})"

        assert_match(/#{Regexp.quote(media_asset_path(media_asset))}/, link)
        assert_match(/#{Regexp.quote(text)}/, link)
      end
    end
  end
end
