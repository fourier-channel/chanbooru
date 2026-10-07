# frozen_string_literal: true

require "test_helper"

# Posts under a creator prefix hidden by the list (CreatorPrefixes visible_to).
# Operator, 2026-10-07: aichan_ posts hidden by default, "admins only, for
# now". The rule joins Post.hidden_from / #hidden_from?, so every door that
# already honours them honours it; these are the doors a member would try.
class CreatorPrefixVisibilityTest < ActionDispatch::IntegrationTest
  LIST = <<~YAML
    editors: [tunnel, sample]
    prefixes:
      - {prefix: 4chan_, provenance: Imageboard/web surface, target_kind: site, target: www.4chan.org, scope: x}
      - {prefix: 41chan_, provenance: Matrix, target_kind: server, target: matrix.41chan.net, scope: x}
      - {prefix: aichan_, provenance: Discord, target_kind: server, target: AIChan, scope: x, visible_to: VIS}
  YAML

  def write_list(visibility)
    tmp = "#{@path}.tmp"
    File.write(tmp, LIST.sub("VIS", visibility))
    File.rename(tmp, @path)
  end

  def ids_for(user, **params)
    # A signed-out request needs a fresh session: an integration test keeps
    # the last request's login cookie.
    user ? get_auth(posts_path(format: :json), user, params: params) : (reset!; get(posts_path(format: :json), params: params))
    assert_response :success
    response.parsed_body.pluck("id")
  end

  def status_for(post, user)
    user ? get_auth(post_path(post, format: :json), user) : (reset!; get(post_path(post, format: :json)))
    response.status
  end

  setup do
    @dir = Dir.mktmpdir("creator-prefix-visibility")
    @path = File.join(@dir, "creator_prefixes.yml")
    @was = ENV["FOURIER_CREATOR_PREFIXES"]
    ENV["FOURIER_CREATOR_PREFIXES"] = @path
    CreatorPrefixes.reset!
    write_list("admins")

    @tunnel = create(:builder_user, name: "tunnel")
    @member = create(:user)
    @gold = create(:gold_user)
    @admin = create(:admin_user)
    as(@tunnel) do
      @hidden = create(:post, uploader: @tunnel, tag_string: "aichan_alice landscape")
      @shown = create(:post, uploader: @tunnel, tag_string: "4chan_bob landscape")
    end
  end

  teardown do
    ENV["FOURIER_CREATOR_PREFIXES"] = @was
    CreatorPrefixes.reset!
    FileUtils.rm_rf(@dir)
  end

  context "an aichan_ post, admins only" do
    should "be not found for a signed-out visitor, a member and a gold member" do
      [nil, @member, @gold].each do |user|
        assert_equal 404, status_for(@hidden, user), user&.name || "anonymous"
        assert_equal 200, status_for(@shown, user), user&.name || "anonymous"
      end
    end

    should "be seen by an admin and by the posting account" do
      [@admin, @tunnel].each { |user| assert_equal 200, status_for(@hidden, user), user.name }
    end

    should "be left out of listings and searches, even searched for by its creator tag" do
      [nil, @member].each do |user|
        assert_not_includes ids_for(user, limit: 100), @hidden.id
        assert_empty ids_for(user, tags: "aichan_alice")
      end
      assert_includes ids_for(@admin, tags: "aichan_alice"), @hidden.id
    end

    should "not be counted for a member, nor its media asset be served" do
      get_auth posts_counts_path(format: :json), @member, params: { tags: "aichan_alice" }
      assert_equal 0, response.parsed_body.dig("counts", "posts")
      get_auth posts_counts_path(format: :json), @admin, params: { tags: "aichan_alice" }
      assert_equal 1, response.parsed_body.dig("counts", "posts")
      # The media gate's own question (fourier-auth asks the booru this).
      assert_not MediaAssetPolicy.new(@member, @hidden.media_asset).can_see_image?
      assert MediaAssetPolicy.new(@admin, @hidden.media_asset).can_see_image?
    end

    should "agree row for row: the relation and the per-post rule" do
      [nil, @member, @gold, @admin, @tunnel].each do |user|
        hidden_rel = Post.hidden_from(user)
        by_rel = hidden_rel ? Post.where(id: [@hidden.id, @shown.id]).merge(hidden_rel).pluck(:id) : []
        by_row = [@hidden, @shown].select { |p| p.hidden_from?(user) }.map(&:id)
        assert_equal by_row.sort, by_rel.sort, user&.name || "anonymous"
      end
    end

    should "keep its creator's name out of the tag index and autocomplete" do
      get_auth tags_path(format: :json), @member, params: { search: { name_matches: "aichan_*" } }
      assert_not_includes response.parsed_body.pluck("name"), "aichan_alice"
      get_auth tags_path(format: :json), @admin, params: { search: { name_matches: "aichan_*" } }
      assert_includes response.parsed_body.pluck("name"), "aichan_alice"
      get_auth autocomplete_index_path(format: :json), @member, params: { search: { query: "aichan_", type: "tag_query" } }
      assert_not_includes response.body, "aichan_alice"
    end
  end

  context "the galleries on artist and wiki pages" do
    setup do
      # As tunnel does on posting: a creator tag is an artist tag.
      as(@admin) { Tag.find_by_name("aichan_alice").update!(category: Tag.categories.artist, updater: @admin) }
      as(@admin) do
        @artist = create(:artist, name: "aichan_alice")
        @wiki = create(:wiki_page, title: "aichan_alice")
      end
    end

    # Found live 2026-10-07: the artist page showed 8 hidden aichan_ posts to
    # a signed-out visitor -- its gallery query skipped the implicit filters.
    should "not show a hidden post to a visitor or a member, and show it to an admin" do
      [nil, @member].each do |user|
        user ? get_auth(artist_path(@artist), user) : (reset!; get(artist_path(@artist)))
        assert_response :success
        assert_select "article#post_#{@hidden.id}", false, "artist page, #{user&.name || "anonymous"}"
        user ? get_auth(wiki_page_path(@wiki), user) : (reset!; get(wiki_page_path(@wiki)))
        assert_select "article#post_#{@hidden.id}", false, "wiki page, #{user&.name || "anonymous"}"
      end
      get_auth artist_path(@artist), @admin
      assert_select "article#post_#{@hidden.id}"
    end
  end

  context "widening it" do
    should "show it to members, not visitors, the moment the list says members" do
      write_list("members")
      assert_equal 200, status_for(@hidden, @member)
      assert_equal 404, status_for(@hidden, nil)
      write_list("everyone")
      assert_equal 200, status_for(@hidden, nil)
    end
  end

  context "a broken list" do
    should "never un-hide anything: the last list read stands" do
      assert_equal 404, status_for(@hidden, @member)
      File.write(@path, "prefixes: [unclosed\n")
      assert_equal 404, status_for(@hidden, @member)
    end
  end
end
