require "test_helper"

module PostSets
  class PostTest < ActiveSupport::TestCase
    # @return [Array] the set's post ids, and the counts it ran
    def ids_and_counts(...)
      sqls = []
      collect = ->(*, payload) { sqls << payload[:sql] }
      ids = ActiveSupport::Notifications.subscribed(collect, "sql.active_record") do
        Cache.clear
        PostSets::Post.new(...).posts.map(&:id)
      end
      [ids, sqls.grep(/SELECT COUNT\(.*\) FROM "posts"/i)]
    end

    context "In all cases" do
      setup do
        @user = create(:user)
        CurrentUser.user = @user

        @post1 = create(:post, tag_string: "a")
        @post2 = create(:post, tag_string: "b")
        @post3 = create(:post, tag_string: "c")
      end

      teardown do
        CurrentUser.user = nil
      end

      context "a set for page 2" do
        should "return the second element" do
          @set = PostSets::Post.new("", 2, 1)
          assert_equal(@post2.id, @set.posts.first.id)
        end
      end

      context "a set for the 'a' tag query" do
        setup do
          @post4 = create(:post, tag_string: "a")
          @post5 = create(:post, tag_string: "a")
        end

        context "with no page" do
          setup do
            @set = PostSets::Post.new("a")
            ::Post.stubs(:records_per_page).returns(1)
          end

          should "return the first element" do
            assert_equal(@post5.id, @set.posts.first.id)
          end
        end

        context "for before the first element" do
          setup do
            @set = PostSets::Post.new("a", "b#{@post5.id}")
            ::Post.stubs(:records_per_page).returns(1)
          end

          should "return the second element" do
            assert_equal(@post4.id, @set.posts.first.id)
          end
        end

        context "for after the second element" do
          setup do
            @set = PostSets::Post.new("a", "a#{@post4.id}")
            @set.stubs(:records_per_page).returns(1)
          end

          should "return the first element" do
            assert_equal(@post5.id, @set.posts.first.id)
          end
        end
      end

      context "a set going to the 1,001st page" do
        setup do
          @set = PostSets::Post.new("a", 1_001)
        end

        should "fail" do
          assert_raises(PaginationExtension::PaginationError) do
            @set.posts
          end
        end
      end

      # Fork (operator, 2026-10-17): "Unlimited tags for members, yes. Leave
      # anon two." What guards the database is the statement timeout, not the
      # number of tags (measured on production: 12 common tags 87 ms, 3 tags
      # of mixed sizes 2 s).
      context "a set for the 'a b c' tag query" do
        context "for a member" do
          should "pass, with any number of tags" do
            @set = PostSets::Post.new("a b c d e f g h i j k l", user: create(:user))

            assert_nothing_raised do
              @set.posts
            end
          end
        end

        context "for a restricted user" do
          should "fail" do
            @set = PostSets::Post.new("a b c", user: create(:restricted_user))

            assert_raises(PostQuery::TagLimitError) do
              @set.posts
            end
          end
        end

        context "for a signed-out viewer" do
          should "fail" do
            @set = PostSets::Post.new("a b c", user: User.anonymous)

            assert_raises(PostQuery::TagLimitError) do
              @set.posts
            end
          end
        end

        context "for a gold user" do
          should "pass" do
            @set = PostSets::Post.new("a b c", user: create(:gold_user))

            assert_nothing_raised do
              @set.posts
            end
          end
        end
      end

      context "a set for the 'a' tag query" do
        setup do
          @set = PostSets::Post.new("a")
        end

        should "normalize its tag query" do
          assert_equal("a", @set.tag_string)
        end

        should "know the count" do
          assert_equal(1, @set.posts.total_count)
        end

        should "find the posts" do
          assert_equal(@post1.id, @set.posts.first.id)
        end

        context "that has a matching wiki page" do
          setup do
            @wiki_page = create(:wiki_page, title: "a")
          end

          should "find the wiki page" do
            assert_not_nil(@set.wiki_page)
            assert_equal(@wiki_page.id, @set.wiki_page.id)
          end
        end

        context "that has a matching artist" do
          should "find the artist" do
            set = PostSets::Post.new("bkub")
            artist = create(:artist, name: "bkub")

            assert_not_nil(set.artist)
            assert_equal(artist, set.artist)
          end
        end
      end

      # Fork (2026-11-24, TAG_RECOUNT.md 2): an API listing is a bare list of
      # rows, so it counts nothing; HTML shows and numbers by the count.
      context "counting a search" do
        setup do
          @posts = [@post1, @post2, @post3, create(:post, tag_string: "b z")].map(&:id).reverse
        end

        %w[json xml].each do |format|
          should "run no count for #{format}, and list what HTML lists" do
            ["", "-source:*nowhere*", "b", "order:id", "id:>0"].each do |tags|
              [[1, 2], [2, 2], [9, 2], ["b#{@posts[1]}", 2], ["a#{@posts[2]}", 2]].each do |page, limit|
                ids, counts = ids_and_counts(tags, page, limit, format: format)
                assert_empty(counts, "#{tags.inspect} page #{page} was counted")
                assert_equal(ids_and_counts(tags, page, limit, format: "html").first, ids, "#{tags.inspect} page #{page}")
              end
            end
          end

          # The count decides a true shuffle or a sample (random_order_pagination_test).
          should "count a random draw for #{format}" do
            ids, counts = ids_and_counts("-source:*nowhere* order:random", 1, 20, format: format)
            assert_equal(1, counts.size)
            assert_equal(@posts.sort, ids.sort)
          end
        end

        should "still count for HTML" do
          _, counts = ids_and_counts("-source:*nowhere*", 1, 2)
          assert_equal(1, counts.size)
          assert_equal(@posts.size, PostSets::Post.new("-source:*nowhere*", 1, 2).posts.total_count)
        end
      end

      context "#per_page method" do
        should "take the limit from the params first, then the limit:<n> metatag, then the account settings" do
          set = PostSets::Post.new("a limit:23 b", 1, 42)
          assert_equal(42, set.per_page)

          set = PostSets::Post.new("a limit:23 b", 1, nil)
          assert_equal(23, set.per_page)

          set = PostSets::Post.new("a", 1, nil)
          assert_equal(CurrentUser.user.per_page, set.per_page)
        end
      end
    end
  end
end
