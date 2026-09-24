require "test_helper"

# The provenance endpoint the posting bots call, driven the way they call it:
# a JSON body with top-level keys.
#
# The model keys (spectrum, hydra) are what light the lamp, and they reach
# record_partition! only if the controller lets them through. Until 2026-09-24
# it did not: wrap_parameters listed the bucket keys and not the model keys,
# so a JSON body's spectrum and hydra lists were never wrapped under
# fourier_tag_source and permit() saw nothing. Measured in production that
# day: 22.4M provenance rows, not one carrying either bit, four days after the
# lamp shipped. The model test passed the whole time because it calls
# record_partition! directly and never goes through this door.
class FourierTagSourcesControllerTest < ActionDispatch::IntegrationTest
  context "POST /posts/:post_id/tag_sources" do
    setup do
      @bot = create(:builder_user)
      @post = create(:post, tag_string: "a b m")
    end

    should "record which model reported each tag" do
      post_auth "/posts/#{@post.id}/tag_sources.json", @bot, as: :json,
        params: { auto: %w[a b], meta: %w[m], spectrum: %w[a m], hydra: %w[a b] }

      assert_response :success
      rows = FourierTagSource.where(post_id: @post.id).index_by(&:tag)
      assert_equal %w[a b m], rows.keys.sort
      assert rows["a"].spectrum? && rows["a"].hydra?, "a was reported by both models"
      assert rows["b"].hydra?, "b was reported by hydra"
      refute rows["b"].spectrum?, "b was not reported by spectrum"
      assert rows["m"].spectrum?, "m was reported by spectrum"
      refute rows["m"].hydra?, "m was not reported by hydra"
    end
  end

  # THE MODEL-BIT BACKFILL (2026-09-24). fourier-sampling's retag timer pushes
  # hydra's tags onto posts that already exist and recorded them with no model
  # bit at all, and 22.4M older rows predate the bits entirely -- the lamp
  # reads "no bit" as spectrum, so hydra's work was invisible and a tag both
  # models found never lit "both". This route is how the bits get there.
  #
  # The contract both repos implement: it ONLY ever ORs model bits in. It
  # never clears a bit, never moves a tag between buckets, never touches
  # public, status or added_by, and never fans out -- a lamp is not part of
  # the public projection.
  def models(user, entries, **opts)
    post_auth "/posts/tag_source_models.json", user, as: :json, params: { posts: entries }, **opts
  end

  def row(post, tag)
    FourierTagSource.find_by(post_id: post.id, tag: tag)
  end

  def everything_about(post)
    FourierTagSource.where(post_id: post.id).order(:tag).pluck(:tag, :source, :status, :public, :added_by, :created_at)
  end

  context "POST /posts/tag_source_models" do
    setup do
      @bot = create(:builder_user)
      @post = create(:post, tag_string: "a b m")
      # Rows as the retag timer left them: model rows with no model bit.
      FourierTagSource.record_partition!(@post, { auto: %w[a b], meta: %w[m] }, @bot)
    end

    should "OR each model's bit into the rows that exist" do
      models(@bot, [{ post_id: @post.id, spectrum: %w[a m], hydra: %w[a b] }])

      assert_response :success
      assert_equal({ "updated" => 3, "inserted" => 0, "skipped" => 0, "missing_posts" => [] }, response.parsed_body)
      assert_equal :both, row(@post, "a").lamp
      assert_equal :hydra, row(@post, "b").lamp
      assert row(@post, "m").spectrum?
      assert_not row(@post, "m").hydra?
      # the bucket each row was in is the bucket it is still in
      assert_equal %i[auto auto meta], %w[a b m].map { |t| row(@post, t).bucket }
    end

    should "authenticate the way the bot does, with an API key over Basic auth" do
      key = create(:api_key, user: @bot)
      auth = "Basic #{::Base64.strict_encode64("#{@bot.name}:#{key.key}")}"

      post "/posts/tag_source_models.json",
           as: :json,
           headers: { HTTP_AUTHORIZATION: auth },
           params: { posts: [{ post_id: @post.id, hydra: %w[b] }] }

      assert_response :success
      assert row(@post, "b").hydra?
    end

    should "insert an approved public auto row for a tag on the post that has none" do
      @post.update!(tag_string: "a b m fresh")

      models(@bot, [{ post_id: @post.id, hydra: %w[fresh] }])

      assert_response :success
      assert_equal 1, response.parsed_body["inserted"]
      fresh = row(@post, "fresh")
      assert_equal FourierTagSource::AUTO | FourierTagSource::HYDRA, fresh.source
      assert_equal FourierTagSource::APPROVED, fresh.status
      assert_equal true, fresh.public
      assert_equal :auto, fresh.bucket
      assert_equal :hydra, fresh.lamp
    end

    should "skip a tag the post does not carry and has no row for" do
      models(@bot, [{ post_id: @post.id, hydra: %w[not_on_this_post] }])

      assert_response :success
      assert_equal({ "updated" => 0, "inserted" => 0, "skipped" => 1, "missing_posts" => [] }, response.parsed_body)
      assert_nil row(@post, "not_on_this_post")
    end

    should "never clear a bit" do
      models(@bot, [{ post_id: @post.id, spectrum: %w[a] }])
      models(@bot, [{ post_id: @post.id, hydra: %w[a] }])
      assert_equal :both, row(@post, "a").lamp

      # a later call naming only one model, or neither, takes nothing away
      models(@bot, [{ post_id: @post.id, spectrum: %w[a], hydra: [] }])
      models(@bot, [{ post_id: @post.id }])
      assert_equal :both, row(@post, "a").lamp
    end

    should "leave a creator's private row private and the creator's" do
      creator = create(:user)
      @post.update!(tag_string: "a b m secret")
      FourierTagSource.record_partition!(@post, { creator: %w[secret] }, creator)
      before = row(@post, "secret")

      models(@bot, [{ post_id: @post.id, hydra: %w[secret] }])

      after = row(@post, "secret")
      assert_equal before.source | FourierTagSource::HYDRA, after.source
      assert after.creator?
      assert_not after.auto?, "a model bit is not the AUTO bit: the tag stays in the creator bucket"
      assert_equal :creator, after.bucket
      assert_equal false, after.public
      assert_equal creator.id, after.added_by
      assert_equal before.status, after.status
      assert_equal before.created_at, after.created_at
    end

    should "report an unknown post and still do the rest" do
      missing = Post.maximum(:id).to_i + 1000

      models(@bot, [{ post_id: missing, hydra: %w[a] }, { post_id: @post.id, hydra: %w[a] }])

      assert_response :success
      assert_equal [missing], response.parsed_body["missing_posts"]
      assert_equal 1, response.parsed_body["updated"]
      assert row(@post, "a").hydra?
    end

    should "change nothing the second time it is sent" do
      @post.update!(tag_string: "a b m fresh")
      body = [{ post_id: @post.id, spectrum: %w[a m], hydra: %w[a b fresh nowhere] }]

      models(@bot, body)
      assert_equal({ "updated" => 3, "inserted" => 1, "skipped" => 1, "missing_posts" => [] }, response.parsed_body)
      first = everything_about(@post)

      models(@bot, body)
      assert_response :success
      assert_equal({ "updated" => 0, "inserted" => 0, "skipped" => 5, "missing_posts" => [] }, response.parsed_body)
      assert_equal first, everything_about(@post)
    end

    should "resolve names through the booru's aliases, as record_partition! does" do
      create(:tag_alias, antecedent_name: "old_name", consequent_name: "new_name")
      @post.update!(tag_string: "a b m new_name")

      models(@bot, [{ post_id: @post.id, hydra: %w[old_name] }])

      assert_response :success
      assert_nil row(@post, "old_name")
      assert row(@post, "new_name").hydra?
    end

    should "not fan out: a lamp is not part of the public projection" do
      FourierTagPropagation.expects(:fan_out!).never

      models(@bot, [{ post_id: @post.id, hydra: %w[a] }])

      assert_response :success
    end

    should "refuse anyone below builder" do
      models(create(:user), [{ post_id: @post.id, hydra: %w[a] }])

      assert_response 403
      assert_not row(@post, "a").hydra?
    end

    should "refuse an empty or oversized batch with 422, and say what to send" do
      models(@bot, [])
      assert_response 422
      assert_match(/1 to 100/, response.parsed_body["error"])

      models(@bot, Array.new(101) { { post_id: @post.id, hydra: %w[a] } })
      assert_response 422
      assert_not row(@post, "a").hydra?
    end

    should "refuse a post id that is not a number" do
      models(@bot, [{ post_id: "abc", hydra: %w[a] }])

      assert_response 422
      assert_match(/post_id/, response.parsed_body["error"])
    end
  end
end
