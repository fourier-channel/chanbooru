require "test_helper"

class TagSetPresenterTest < ActiveSupport::TestCase
  # A roll that always lands on the given value (rand(100) -> n).
  def self.roll(n) = Struct.new(:n) { def rand(_max) = n }.new(n)
  FIRST = roll(0)

  context "TagSetPresenter" do
    setup do
      create(:tag, name: "bkub", category: Tag.categories.artist)
      create(:tag, name: "chen", category: Tag.categories.character)
      create(:tag, name: "cirno", category: Tag.categories.character)
      create(:tag, name: "cirno_(tanned)", category: Tag.categories.character)
      create(:tag, name: "solo", category: Tag.categories.general)
      create(:tag, name: "touhou", category: Tag.categories.copyright)
      create(:tag, name: "touhou_(pc-98)", category: Tag.categories.copyright)

      @categories = %w[copyright character artist meta general]
    end

    context "#split_tag_list_text method" do
      should "list all categories in order" do
        text = TagSetPresenter.new(%w[bkub chen cirno solo touhou]).split_tag_list_text(category_list: @categories)
        assert_equal("touhou \nchen cirno \nbkub \nsolo", text)
      end

      should "skip empty categories" do
        text = TagSetPresenter.new(%w[bkub solo]).split_tag_list_text(category_list: @categories)
        assert_equal("bkub \nsolo", text)
      end
    end

    context "the post page title" do
      should "work" do
        post_title = TagSetPresenter.new(%w[bkub cirno chen touhou], rng: FIRST).humanized_essential_tag_string
        assert_equal("chen and cirno (touhou) created by bkub", post_title)
      end

      should "not display duplicate chartags" do
        post_title = TagSetPresenter.new(%w[bkub cirno cirno_(tanned) touhou], rng: FIRST).humanized_essential_tag_string
        assert_equal("cirno (touhou) created by bkub", post_title)
      end

      should "not display duplicate copytags" do
        post_title = TagSetPresenter.new(%w[bkub cirno touhou_(pc-98) touhou], rng: FIRST).humanized_essential_tag_string
        assert_equal("cirno (touhou) created by bkub", post_title)
      end

      should "work without a copyright tag" do
        post_title = TagSetPresenter.new(%w[bkub cirno cirno_(tanned)], rng: FIRST).humanized_essential_tag_string
        assert_equal("cirno created by bkub", post_title)
      end

      should "work without an artist tag" do
        post_title = TagSetPresenter.new(%w[touhou cirno cirno_(tanned)], rng: FIRST).humanized_essential_tag_string
        assert_equal("cirno (touhou)", post_title)
      end

      should "work without a chartag tag" do
        post_title = TagSetPresenter.new(%w[touhou bkub], rng: FIRST).humanized_essential_tag_string
        assert_equal("touhou created by bkub", post_title)
      end

      should "work with only an artist tag" do
        post_title = TagSetPresenter.new(%w[bkub], rng: FIRST).humanized_essential_tag_string
        assert_equal("created by bkub", post_title)
      end

      should "credit 'created by' on rolls 0 to 93 and each other phrase on one roll" do
        phrases = (0..99).map { |n| TagSetPresenter.credit_phrase(TagSetPresenterTest.roll(n)) }
        assert_equal(94, phrases.count("created by"))
        TagSetPresenter::CREDIT_PHRASES.drop(1).each do |phrase, _|
          assert_equal(1, phrases.count(phrase), phrase)
        end
        assert_equal("the output from twenty five gallons of water boiled by", phrases[99])
      end

      should "put the drawn phrase in the title" do
        post_title = TagSetPresenter.new(%w[bkub cirno], rng: TagSetPresenterTest.roll(97)).humanized_essential_tag_string
        assert_equal("cirno hallucinated by bkub", post_title)
      end

      should "never say drawn by" do
        titles = (0..99).map { |n| TagSetPresenter.new(%w[bkub], rng: TagSetPresenterTest.roll(n)).humanized_essential_tag_string }
        assert(titles.none? { |t| t.include?("drawn by") })
      end

      should "work with no relevant tags" do
        post_title = TagSetPresenter.new(%w[tagme], rng: FIRST).humanized_essential_tag_string
        assert_equal("", post_title)
      end
    end
  end
end
