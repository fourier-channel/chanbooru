require "test_helper"

# The board filter on the Modulation gallery.
#
# Provenance on this site lives in the post's SOURCE, not in a tag, so the
# filter is a `source:` metatag with a trailing wildcard. That is the part
# worth testing: the wildcard form is easy to write and easy to get subtly
# wrong, and nothing else in the suite covers it.
#
# The second thing worth testing is the whole-term match. `matrix` is both an
# ordinary word someone will search for and the name of one of the four
# segments, and a substring test would light that segment up for anyone
# searching the tag. That is the bug this file exists to prevent.
class ModulationBoardFilterTest < ActionDispatch::IntegrationTest
  BOARDS = ModulationGalleryComponent::BOARDS

  context "The Modulation board filter" do
    setup do
      @user = travel_to(1.month.ago) { create(:user) }
      @posts = as(@user) do
        {
          "b" => create(:post, source: "https://boards.4chan.org/b/thread/11#p12", tag_string: "aaaa"),
          "d" => create(:post, source: "https://boards.4chan.org/d/thread/21#p22", tag_string: "bbbb"),
          "trash" => create(:post, source: "https://boards.4chan.org/trash/thread/31#p32", tag_string: "cccc"),
          "matrix" => create(:post, source: "mxc://41chan.net/AbCdEfGhIjKl", tag_string: "dddd"),
        }
      end
    end

    context "the search each segment performs" do
      should "return that board's posts and no others" do
        BOARDS.each do |board|
          posts = PostQuery.normalize(board[:source], current_user: @user).posts.to_a

          assert_includes(posts, @posts[board[:key]],
                          "#{board[:label]} did not match its own post")

          @posts.except(board[:key]).each do |other_key, other_post|
            assert_not_includes(posts, other_post,
                                "#{board[:label]} wrongly matched the #{other_key} post")
          end
        end
      end

      should "not match a post from another board that merely shares a prefix" do
        # /b/ must not swallow a board whose name starts with b. Without the
        # trailing slash in the pattern it would.
        bant = as(@user) { create(:post, source: "https://boards.4chan.org/bant/thread/41#p42") }
        posts = PostQuery.normalize(BOARDS.find { |b| b[:key] == "b" }[:source], current_user: @user).posts.to_a

        assert_not_includes(posts, bant)
      end
    end

    context "the control itself" do
      should "render one segment per board" do
        get posts_path(preset: "modulation")

        assert_response :success
        assert_select "nav.modgal-boards a", count: BOARDS.size
        BOARDS.each do |board|
          assert_select "nav.modgal-boards a", text: board[:label]
        end
      end

      should "mark the chosen segment active and leave the rest alone" do
        board = BOARDS.find { |b| b[:key] == "d" }
        get posts_path(preset: "modulation", tags: board[:source])

        assert_response :success
        assert_select "nav.modgal-boards a.is-active", count: 1
        assert_select "nav.modgal-boards a.is-active", text: board[:label]
      end

      should "mark nothing active for a search that merely contains the word matrix" do
        get posts_path(preset: "modulation", tags: "dddd")

        assert_response :success
        assert_select "nav.modgal-boards a.is-active", count: 0
      end

      should "clear the filter when the active segment is chosen again" do
        board = BOARDS.find { |b| b[:key] == "trash" }
        get posts_path(preset: "modulation", tags: board[:source])

        assert_response :success
        # The active segment's own link must no longer carry the term -- that
        # toggle is the only way back to "all boards" on a four-part control.
        assert_select "nav.modgal-boards a.is-active" do |links|
          assert_no_match(/source%3A/i, links.first["href"].to_s,
                          "the active segment still filters, so it cannot be turned off")
        end
      end

      should "keep the rest of the search when a board is chosen" do
        get posts_path(preset: "modulation", tags: "aaaa order:id")

        assert_response :success
        assert_select "nav.modgal-boards a" do |links|
          href = links.first["href"].to_s
          assert_match(/aaaa/, href, "choosing a board dropped the search terms")
          assert_match(/order/, href, "choosing a board dropped the sort")
        end
      end
    end
  end
end
