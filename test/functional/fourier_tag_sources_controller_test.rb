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
end
