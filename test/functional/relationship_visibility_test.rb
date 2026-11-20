# frozen_string_literal: true

require "test_helper"

# boo.122 D2 (2026-11-20): a post's relatives were judged by the DELETION half
# of the hidden rule only (Post.hidden_as_deleted_sql). So an admin, who sees
# deleted posts, found a visible post through a JAILED relative -- parent:any,
# child:any, search[has_children], search[has_active_children] -- and a member
# found one through every LIVE hidden relative: a half-jailed post, a released
# banished name, a creator-hidden, flagged, gated, prefix or rooms post. The
# commentary form printed a hidden parent's id, the Discord embed's colour
# told of a hidden relative, the depth and child-count refusals counted hidden
# relatives, and a viewer's parent:/child: count was cached for the next.
#
# Post.hidden_relative_sql asks the whole rule (Post.hidden_from) of the
# relative. Deleted-post visibility and the banished-post rule are relaxed
# under test, so both are stubbed to the production shape, and the fixture
# asserts every relative is hidden (or not) from whom it stands for.
class RelationshipVisibilityTest < ActionDispatch::IntegrationTest
  JAIL = "troll_jail"
  MISSING = 999_999

  def ids(path, user, params = {})
    get_auth path, user, params: params, as: :json
    assert_equal 200, response.status, "#{path} #{params.inspect} as #{user.name}"
    response.parsed_body.pluck("id")
  end

  def found(user, tags)
    ids(posts_path, user, tags: tags, limit: 100)
  end

  # search[has_parent] and the rest reach Post.search through a nested
  # search[post][...] of another model (the commentary test below);
  # /posts.json reads tags only, and would answer every post.
  def searched(user, search)
    as(user) { Post.search(search, user).pluck(:id) }
  end

  def count(user, tags)
    get_auth posts_counts_path(format: :json), user, params: { tags: tags }
    assert_response :success
    response.parsed_body.dig("counts", "posts")
  end

  # Jailed as sampling jails: the tag, then the deletion, by the panel's account.
  def jail!(post)
    as(@sample) { post.reload.update!(tag_string: "landscape #{JAIL}") }
    post.reload.delete!("troll jail: shock", user: @sample)
    post.reload
  end

  # troll_jail on a live post: a jailing whose delete half never landed. It
  # stays hidden from everyone but the pipeline (fail closed), and is live.
  def half_jail!(post)
    post.update_columns(tag_string: "landscape #{JAIL}")
    post.reload
  end

  def family
    parent = as(@uploader) { create(:post, uploader: @uploader, tag_string: "landscape") }
    child = as(@uploader) { create(:post, uploader: @uploader, tag_string: "landscape", parent: parent) }
    [parent.reload, child.reload]
  end

  setup do
    Danbooru.config.stubs(:deleted_post_visibility_level).returns(User::Levels::ADMIN)
    Danbooru.config.stubs(:banished_posts_withheld?).returns(true)
    CreatorPrefixes.reset!

    @admin = create(:admin_user)
    @member = create(:user)
    @sample = create(:approver_user, name: "sample")
    @uploader = create(:contributor_user) # posts dozens of fixtures: no upload limit
    @first_version = PostVersion.maximum(:id).to_i

    @jailed_parent, @child_of_jailed = family
    jail!(@jailed_parent)
    @parent_of_jailed, @jailed_child = family
    jail!(@jailed_child)
    @half_parent, @child_of_half = family
    half_jail!(@half_parent)
    @parent_of_half, @half_child = family
    half_jail!(@half_child)
    @deleted_parent, @child_of_deleted = family
    @deleted_parent.delete!("ordinary deletion", user: @admin)
    @open_parent, @open_child = family

    [@jailed_parent, @jailed_child].each do |post|
      assert post.reload.jailed? && post.hidden_from?(@admin), "fixture: ##{post.id} jailed, hidden from an admin"
    end
    [@half_parent, @half_child].each do |post|
      assert !post.is_deleted? && post.hidden_from?(@admin) && post.hidden_from?(@member), "fixture: ##{post.id} live and hidden"
    end
    # The pipeline is spared the jail, not deletion: sample is level 37 and
    # deleted posts show from 50 on production, so it sees a half-jailed post
    # (live) and not a jailed one.
    [@half_parent, @half_child].each do |post|
      assert_not post.hidden_from?(@sample), "fixture: the pipeline sees ##{post.id}"
    end
    assert_not @deleted_parent.reload.hidden_from?(@admin), "fixture: an admin sees an ordinary deletion"
    assert @deleted_parent.hidden_from?(@member), "fixture: a member does not"
    assert @parent_of_half.reload.has_active_children?, "fixture: the stored flag counts the hidden live child"
    assert @parent_of_jailed.reload.has_children?, "fixture: the stored flag counts the jailed child"
    [@child_of_jailed, @child_of_half, @child_of_deleted, @open_child].each do |child|
      assert child.reload.parent_id.present?, "fixture: ##{child.id} names its parent"
    end
  end

  should "not let an admin find a post through a jailed or half-jailed relative" do
    assert_not_includes found(@admin, "parent:any"), @child_of_jailed.id
    assert_not_includes found(@admin, "parent:any"), @child_of_half.id
    assert_includes found(@admin, "parent:none"), @child_of_jailed.id
    assert_not_includes found(@admin, "child:any"), @parent_of_jailed.id
    assert_not_includes found(@admin, "child:any"), @parent_of_half.id
    assert_includes found(@admin, "child:none"), @parent_of_half.id

    has_parent = searched(@admin, has_parent: "true")
    assert_not_includes has_parent, @child_of_jailed.id
    assert_includes has_parent, @open_child.id, "control"
    has_children = searched(@admin, has_children: "true")
    assert_not_includes has_children, @parent_of_jailed.id
    assert_not_includes has_children, @parent_of_half.id
    assert_includes has_children, @open_parent.id, "control"

    assert_includes found(@admin, "parent:any"), @child_of_deleted.id, "control: an admin sees a deleted parent"

    # A range is matched as given (an exact id is answered as missing first).
    range = ->(post) { searched(@admin, parent_id: "#{post.id}..#{post.id}") }
    assert_equal [@open_child.id], range.call(@open_parent), "control"
    assert_empty range.call(@jailed_parent)
    assert_empty range.call(@half_parent)
  end

  should "not let a member find a post through a live hidden relative" do
    assert_not_includes found(@member, "parent:any"), @child_of_half.id
    assert_includes found(@member, "parent:none"), @child_of_half.id
    assert_not_includes found(@member, "child:any"), @parent_of_half.id
    assert_includes found(@member, "parent:any"), @open_child.id, "control"
    assert_includes found(@member, "child:any"), @open_parent.id, "control"
  end

  should "answer search[has_active_children] with live children the searcher may see" do
    [@admin, @member].each do |user|
      active = searched(user, has_active_children: "true")
      assert_not_includes active, @parent_of_half.id, user.name
      assert_includes active, @open_parent.id, "control, #{user.name}"

      inactive = searched(user, has_active_children: "false")
      assert_includes inactive, @parent_of_half.id, user.name
      assert_not_includes inactive, @open_parent.id, "control, #{user.name}"
    end
  end

  should "agree with Post#hidden_from? for every viewer" do
    children = [@child_of_jailed, @child_of_half, @child_of_deleted, @open_child]
    parents = [@parent_of_jailed, @parent_of_half, @open_parent]

    [@admin, @member, @sample].each do |user|
      expected = children.select { |c| !c.hidden_from?(user) && !c.parent.hidden_from?(user) }.map(&:id)
      assert_equal expected.sort, (found(user, "parent:any") & children.map(&:id)).sort, "parent:any, #{user.name}"

      expected = parents.select { |p| !p.hidden_from?(user) && p.children.any? { |c| !c.hidden_from?(user) } }.map(&:id)
      assert_equal expected.sort, (found(user, "child:any") & parents.map(&:id)).sort, "child:any, #{user.name}"
    end
  end

  should "let the pipeline find a post through its half-jailed relative" do
    assert_includes found(@sample, "parent:any"), @child_of_half.id
    assert_includes found(@sample, "child:any"), @parent_of_half.id
    assert_includes searched(@sample, has_active_children: "true"), @parent_of_half.id
  end

  should "answer a nested post search through a hidden parent as a missing one" do
    jailed = as(@uploader) { create(:artist_commentary, post: @child_of_jailed) }
    open = as(@uploader) { create(:artist_commentary, post: @open_child) }

    rows = ids(artist_commentaries_path, @admin, search: { post: { has_parent: "true" } })
    assert_includes rows, open.id, "control"
    assert_not_includes rows, jailed.id
  end

  should "not name a jailed parent in the child's versions" do
    own = ->(search) { ids(post_versions_path, @admin, search: search.merge(post_id: @child_of_jailed.id)) }
    assert_not_empty own.call({}).select { |id| id > @first_version }, "fixture: the child has versions"

    assert_equal own.call(parent_id: MISSING), own.call(parent_id: @jailed_parent.id), "search[parent_id]"
    assert_equal own.call(parent_id_not: MISSING), own.call(parent_id_not: @jailed_parent.id), "search[parent_id_not]"

    # An exact id is answered as a missing one before the search runs
    # (Post.parent_ids_named_to); a range is matched as given and narrowed
    # by PostVersion.unnamed_parent_condition.
    range = ->(id) { "#{id}..#{id}" }
    assert_not_empty own.call(parent_id_not: range.call(MISSING)), "fixture: a range finds the child's versions"
    assert_equal own.call(parent_id: range.call(MISSING)), own.call(parent_id: range.call(@jailed_parent.id)), "search[parent_id] range"
    assert_equal own.call(parent_id_not: range.call(MISSING)), own.call(parent_id_not: range.call(@jailed_parent.id)), "search[parent_id_not] range"
  end

  should "not print a hidden parent's id in the commentary form" do
    form_parent = lambda do |post|
      get_auth post_path(post), @admin
      assert_response :success
      assert_includes response.body, 'name="commentary_post_id"', "fixture: the page draws the commentary form"
      response.body[/name="commentary_post_id"[^>]*value="(\d+)"/, 1]
    end

    assert_equal @open_parent.id.to_s, form_parent.call(@open_child), "control: the form carries a visible parent"
    assert_nil form_parent.call(@child_of_jailed)
  end

  should "not colour the Discord embed for a hidden relative" do
    colour = ->(post) { DiscordSlashCommand::PostEmbed.new(post.reload, nil).send(:embed_color) }

    assert_equal 0xC0C000, colour.call(@open_child), "control: a child's colour"
    assert_not_equal 0xC0C000, colour.call(@child_of_half)
    assert_not_equal colour.call(@open_parent), colour.call(@parent_of_half)
  end

  should "not serve one viewer's relationship count to the next" do
    # The test cache is a null store, which caches nothing to serve.
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    # A peer of the uploader's level: the same hidden-tags digest and the
    # same implicit terms, so only the key's viewer tells the two apart.
    peer = create(:contributor_user)
    assert_not @deleted_parent.hidden_from?(@uploader), "fixture: the uploader sees its own deletion"
    assert @deleted_parent.hidden_from?(peer), "fixture: the peer does not"
    search = "parent:any id:#{@child_of_deleted.id}"
    key = ->(user) { PostQuery.normalize(search, current_user: user).with_implicit_metatags.send(:count_cache_key).split(":", 3).last }
    assert_equal key.call(@uploader).sub(/\A\d+:/, ""), key.call(peer).sub(/\A\d+:/, ""), "fixture: nothing but the viewer separates the keys"

    assert_equal 1, count(@uploader, search)
    assert_equal 0, count(peer, search)
    Rails.cache.clear
    assert_equal 0, count(peer, search)
    assert_equal 1, count(@uploader, search)
  end

  context "The depth and child-count refusals" do
    setup do
      @own = as(@member) { create(:post, uploader: @member, tag_string: "landscape") }
    end

    should "not count hidden ancestors" do
      # top <- a <- b <- tip: depth 4, the most there may be.
      top = as(@uploader) { create(:post, uploader: @uploader, tag_string: "landscape") }
      a = as(@uploader) { create(:post, uploader: @uploader, tag_string: "landscape", parent: top) }
      b = as(@uploader) { create(:post, uploader: @uploader, tag_string: "landscape", parent: a) }
      tip = as(@uploader) { create(:post, uploader: @uploader, tag_string: "landscape", parent: b) }

      put_auth post_path(@own, format: :json), @member, params: { post: { parent_id: tip.id }}
      assert_nil @own.reload.parent_id, "control: a fifth level is refused through visible posts"

      [top, a, b].each { |post| half_jail!(post) }
      put_auth post_path(@own, format: :json), @member, params: { post: { parent_id: tip.id }}
      assert_response :success
      assert_equal tip.id, @own.reload.parent_id
    end

    should "not count hidden children" do
      parent = as(@uploader) { create(:post, uploader: @uploader, tag_string: "landscape") }
      children = Array.new(Post::MAX_CHILD_POSTS) { as(@uploader) { create(:post, uploader: @uploader, tag_string: "landscape") } }
      Post.where(id: children.map(&:id)).update_all(parent_id: parent.id)

      put_auth post_path(@own, format: :json), @member, params: { post: { parent_id: parent.id }}
      assert_nil @own.reload.parent_id, "control: a full family is refused"

      half_jail!(children.first)
      put_auth post_path(@own, format: :json), @member, params: { post: { parent_id: parent.id }}
      assert_response :success
      assert_equal parent.id, @own.reload.parent_id
    end
  end
end
