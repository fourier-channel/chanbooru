# frozen_string_literal: true

require "test_helper"

class FourierTagSourceTest < ActiveSupport::TestCase
  context "FourierTagSource" do
    setup do
      @user = create(:user)
      # @user is this post's CREATOR by the uploader rule: a person uploaded it
      # and no creator is recorded (FourierCreatorPrivacy). Until 2026-09-29
      # the creator was whoever the private rows named as added_by -- which,
      # for every tunnel post, is the posting bot.
      @post = create(:post, uploader: @user)
    end

    should "map source/status to the right UI bucket" do
      assert_equal :both,    FourierTagSource.new(source: FourierTagSource::CREATOR | FourierTagSource::AUTO).bucket
      assert_equal :creator, FourierTagSource.new(source: FourierTagSource::CREATOR).bucket
      assert_equal :auto,    FourierTagSource.new(source: FourierTagSource::AUTO).bucket
      assert_equal :meta,    FourierTagSource.new(source: FourierTagSource::META).bucket
      assert_equal :pending, FourierTagSource.new(source: FourierTagSource::HUMAN, status: FourierTagSource::PENDING).bucket
    end

    should "record a provenance partition idempotently per (post, tag)" do
      FourierTagSource.record_partition!(@post, { "creator" => ["c"], "auto" => ["a"], "both" => ["b"], "meta" => ["highres"], "pending" => ["p"] }, @user)
      assert_equal 5, FourierTagSource.where(post_id: @post.id).count
      assert_equal :both, FourierTagSource.find_by(post_id: @post.id, tag: "b").bucket
      assert_equal :pending, FourierTagSource.find_by(post_id: @post.id, tag: "p").bucket

      # re-recording the same tags does not duplicate rows
      FourierTagSource.record_partition!(@post, { "creator" => ["c"] }, @user)
      assert_equal 5, FourierTagSource.where(post_id: @post.id).count
    end

    should "keep creator-only tags private and out of the public projection" do
      # Both readers intersect against post.tag_string (a sidecar row whose tag
      # was since removed is not a tag the post has), so the post must actually
      # carry these. Until 2026-09-20 it did not and the assertions passed on an
      # unpruned sidecar -- then the intersection landed and they went red with
      # nothing running them.
      @post.update!(tag_string: "a b highres")
      FourierTagSource.record_partition!(@post, { "creator" => ["secret"], "auto" => ["a"], "both" => ["b"], "meta" => ["highres"] }, @user)
      assert_equal false, FourierTagSource.find_by(post_id: @post.id, tag: "secret").public
      proj = FourierTagSource.matrix_projection(@post)
      refute_includes proj[:tags], "secret"
      assert_empty proj[:sources][:creator]
      assert_includes proj[:tags], "a"
    end

    # THE LAMP (operator ruling 2026-09-20). None of this was covered the
    # evening the lamp shipped, and the post page 500d in production.
    should "light the lamp for the model that reported the tag" do
      assert_equal :both,     FourierTagSource.new(source: FourierTagSource::AUTO | FourierTagSource::SPECTRUM | FourierTagSource::HYDRA).lamp
      assert_equal :hydra,    FourierTagSource.new(source: FourierTagSource::AUTO | FourierTagSource::HYDRA).lamp
      assert_equal :spectrum, FourierTagSource.new(source: FourierTagSource::AUTO | FourierTagSource::SPECTRUM).lamp
      # a model row from before the bits existed still reads as spectrum
      assert_equal :spectrum, FourierTagSource.new(source: FourierTagSource::AUTO).lamp
      assert_equal :spectrum, FourierTagSource.new(source: FourierTagSource::META).lamp
      # nobody's model: a creator's prompt, or a human edit
      assert_equal :manual,   FourierTagSource.new(source: FourierTagSource::CREATOR).lamp
      assert_equal :manual,   FourierTagSource.new(source: FourierTagSource::HUMAN, status: FourierTagSource::PENDING).lamp
    end

    # The gallery lights a lamp from a page's bit_or(source), which is a source
    # value with no row behind it -- so the rule takes a value, and #lamp
    # delegates to it. Checked against the rule as the row's own predicates
    # state it, for every combination of the six bits: comparing lamp_of with
    # #lamp would compare the method with itself.
    should "light the lamp from a bare source value exactly as the predicates say" do
      (0..63).each do |source|
        row = FourierTagSource.new(source: source)
        expected =
          if row.spectrum? && row.hydra? then :both
          elsif row.hydra? then :hydra
          elsif row.spectrum? || row.auto? || row.meta? then :spectrum
          else :manual
          end
        assert_equal expected, FourierTagSource.lamp_of(source), "source #{source}"
        assert_equal expected, row.lamp, "source #{source}, through the row"
      end
    end

    should "report which model saw each tag, beside the buckets" do
      @post.update!(tag_string: "a b m")
      FourierTagSource.record_partition!(
        @post, { "auto" => %w[a b], "meta" => ["m"], "spectrum" => %w[a], "hydra" => %w[a b] }, @user
      )
      _buckets, lamp = FourierTagSource.buckets_and_lamps_for(@post, nil)
      assert_includes lamp[:both], "a"
      assert_includes lamp[:hydra], "b"
      assert_includes lamp[:spectrum], "m"
      assert_includes FourierTagSource.matrix_projection(@post)[:lamp][:both], "a"
    end

    should "light an unsourced tag's lamp white -- no row means no model" do
      @post.update!(tag_string: "a byhand")
      FourierTagSource.record_partition!(@post, { "auto" => ["a"], "spectrum" => ["a"] }, @user)
      buckets, lamp = FourierTagSource.buckets_and_lamps_for(@post, nil)
      assert_includes buckets[:unsourced], "byhand"
      assert_includes lamp[:manual], "byhand"
      refute_includes lamp[:spectrum], "byhand"
    end

    should "answer one live read with everything a pool needs, and no private tag" do
      @post.update!(tag_string: "a secret bkub 1girl")
      # update_columns, not update!: Versionable needs a CurrentUser and the
      # category is all this test cares about.
      Tag.find_or_create_by_name("bkub").update_columns(category: TagCategory::ARTIST)
      FourierTagSource.record_partition!(
        @post, { "creator" => ["secret"], "auto" => %w[a bkub 1girl], "hydra" => ["a"] }, @user
      )

      anon = FourierTagSource.live_read(@post, nil)
      assert_equal @post.rating, anon[:rating]
      assert_includes anon[:categories]["artist"], "bkub"
      assert_includes anon[:categories]["general"], "a"
      assert_includes anon[:lamp][:hydra], "a"

      # THE PRIVATE TAG IS NOWHERE. Not in a bucket, not in a category, and
      # above all not in tag_string -- which a client sends back as
      # old_tag_string, so a leak here would also be a client holding it.
      refute_includes anon[:tag_string].split, "secret"
      assert_empty anon[:categories].values.flatten.select { |n| n == "secret" }
      assert_empty anon[:creator]

      # The creator sees their own, in every one of those places.
      mine = FourierTagSource.live_read(@post, @user)
      assert_includes mine[:creator], "secret"
      assert_includes mine[:tag_string].split, "secret"
      assert_includes mine[:categories].values.flatten, "secret"
    end

    # THE STRUCTURAL GUARD. for_viewer's every value is a list of tag names,
    # and its callers flatten those values without looking -- `buckets.values
    # .flatten` into Tag.categories_for, and a banishment filter that calls
    # `.reject` on each. The lamps rode inside this hash for one evening and
    # fed a Hash to Digest::SHA256, which took every post page down with a
    # TypeError. A shape assertion is the only thing that catches the NEXT key.
    should "return only lists of tag names from for_viewer" do
      @post.update!(tag_string: "a b")
      FourierTagSource.record_partition!(@post, { "auto" => %w[a b], "hydra" => %w[a] }, @user)
      FourierTagSource.for_viewer(@post, nil).each do |key, value|
        assert_kind_of Array, value, "for_viewer[#{key.inspect}] must be a list of tag names"
        value.each { |name| assert_kind_of String, name, "for_viewer[#{key.inspect}] must hold tag names" }
      end
    end

    # THE TUNNEL'S SHAPE since 37270f5 (2026-08-06): a creator-only tag is its
    # private row and nothing else -- it is NOT in tag_string. Round two drew
    # rows only for tags in tag_string, so every real creator got an empty
    # creator bucket while the privacy rule said yes, and every test passed
    # because each fixture put the private tag in tag_string as well
    # (round-two finding 1).
    should "draw a creator's private rows for the creator though tag_string does not carry them" do
      @post.update!(tag_string: "a")
      FourierTagSource.record_partition!(@post, { "creator" => ["secret"], "auto" => ["a"] }, @user)
      refute_includes @post.reload.tag_array, "secret", "the fixture must be the tunnel's shape"

      mine = FourierTagSource.for_viewer(@post, @user)
      assert_equal ["secret"], mine[:creator]
      assert_empty mine[:unsourced]
      live = FourierTagSource.live_read(@post, @user)
      assert_includes live[:tag_string].split, "secret"
      assert_includes live[:categories].values.flatten, "secret"
      _buckets, lamps = FourierTagSource.buckets_and_lamps_for(@post, @user)
      assert_includes lamps[:manual], "secret"
      assert_includes FourierTagSource.blacklist_tags_for([@post], @user)[@post], "secret"

      [nil, User.anonymous, create(:user), create(:moderator_user), create(:admin_user)].each do |viewer|
        label = viewer&.level_string.inspect
        assert_empty FourierTagSource.for_viewer(@post, viewer).values.flatten.grep(/secret/), label
        refute_includes FourierTagSource.live_read(@post, viewer)[:tag_string].split, "secret", label
        refute_includes FourierTagSource.blacklist_tags_for([@post], viewer)[@post], "secret", label
      end
    end

    # The 2026-09-20 fix stands for PUBLIC rows: a tag removed from tag_string
    # leaves its row behind, and that row is drawn for nobody -- the creator
    # included. Only the creator's PRIVATE rows are exempt from the
    # intersection, because their tags are never in tag_string to begin with.
    should "still drop a public row whose tag has left tag_string, for the creator too" do
      @post.update!(tag_string: "a b")
      FourierTagSource.record_partition!(@post, { "creator" => ["secret"], "auto" => %w[a b] }, @user)
      @post.update!(tag_string: "a")

      mine = FourierTagSource.for_viewer(@post, @user)
      refute_includes mine.values.flatten, "b"
      assert_includes mine[:creator], "secret"
      refute_includes FourierTagSource.for_viewer(@post, nil).values.flatten, "b"
    end

    # The shape of posts from 2026-08-04..06 (fourier-tunnel e5e7e19), when the
    # tunnel put creator tags into tag_string as well. Production still holds
    # one (script/fourier_remove_private_tags_from_tag_string.rb takes it out).
    should "surface private tags to the creator but not to anonymous viewers" do
      @post.update!(tag_string: "secret a")
      FourierTagSource.record_partition!(@post, { "creator" => ["secret"], "auto" => ["a"] }, @user)
      assert_includes FourierTagSource.for_viewer(@post, @user)[:creator], "secret"
      assert_empty FourierTagSource.for_viewer(@post, nil)[:creator]
      assert_includes FourierTagSource.for_viewer(@post, nil)[:auto], "a"
    end

    # Operator ruling 2026-09-29: the creator decides, and nobody holds a role
    # that overrides that. The account that RECORDED the rows is not the
    # creator either -- for a tunnel post that account is the posting bot.
    # In the 2026-08-04..06 shape, where tag_string carries the private tag and
    # blacklist_tags_for has to take it OUT for everyone but the creator.
    should "withhold private tags from a moderator, an admin and the account that recorded them" do
      @post.update!(tag_string: "secret a")
      recorder = create(:builder_user)
      FourierTagSource.record_partition!(@post, { "creator" => ["secret"], "auto" => ["a"] }, recorder)
      assert_equal recorder.id, FourierTagSource.find_by!(post_id: @post.id, tag: "secret").added_by

      [recorder, create(:moderator_user), create(:admin_user)].each do |viewer|
        assert_empty FourierTagSource.for_viewer(@post, viewer)[:creator], viewer.level_string
        refute_includes FourierTagSource.live_read(@post, viewer)[:tag_string].split, "secret", viewer.level_string
        refute_includes FourierTagSource.blacklist_tags_for([@post], viewer)[@post], "secret", viewer.level_string
      end
      assert_includes FourierTagSource.blacklist_tags_for([@post], @user)[@post], "secret"
    end

    should "show private tags to the recorded creator by verified identity, and pass the request through" do
      @post.update!(tag_string: "a")
      FourierTagSource.record_partition!(@post, { "creator" => ["secret"], "auto" => ["a"] }, @user)
      FourierPostCreator.create!(post: @post, mxid: "@alice:41chan.net", recorded_by: @user.id)
      creator = ActionDispatch::TestRequest.create("HTTP_X_FOURIER_IDENTITY" => "@alice:41chan.net")

      assert_empty FourierTagSource.for_viewer(@post, @user)[:creator], "a recorded creator replaces the uploader"
      assert_includes FourierTagSource.for_viewer(@post, nil, request: creator)[:creator], "secret"
      assert_includes FourierTagSource.live_read(@post, nil, request: creator)[:tag_string].split, "secret"
      assert_includes FourierTagSource.blacklist_tags_for([@post], nil, request: creator)[@post], "secret"
    end

    # record_models! reads which rows exist and then writes; the poster writes
    # this table the whole time. A private row that lands between the read and
    # the write meets the insert's ON CONFLICT and falls through to the OR
    # update -- which must not reach it (round-two finding 5). The concurrent
    # writer is played by the insert itself, writing the row just before it.
    should "not rewrite a private row written between record_models!'s read and its write" do
      @post.update!(tag_string: "a secret")
      FourierTagSource.record_partition!(@post, { "auto" => ["a"] }, @user)
      post = @post
      user = @user
      FourierTagSource.singleton_class.define_method(:insert_all) do |*args, **kwargs|
        FourierTagSource.create!(post: post, tag: "secret", source: FourierTagSource::CREATOR, status: FourierTagSource::APPROVED,
                                 public: false, added_by: user.id, created_at: 1.day.ago)
        super(*args, **kwargs)
      end

      result = FourierTagSource.record_models!([{ post_id: @post.id, hydra: ["secret"] }], @user)

      row = FourierTagSource.find_by!(post_id: @post.id, tag: "secret")
      assert_equal FourierTagSource::CREATOR, row.source, "the late private row was rewritten"
      assert_equal false, row.public
      assert_equal({ updated: 0, inserted: 0, skipped: 1, missing_posts: [] }, result)
    ensure
      FourierTagSource.singleton_class.send(:remove_method, :insert_all) if FourierTagSource.singleton_class.method_defined?(:insert_all, false)
    end

    should "show a tag that has no provenance row instead of dropping it" do
      @post.update!(tag_string: "a troll_jail")
      FourierTagSource.record_partition!(@post, { "auto" => ["a"] }, @user)

      buckets = FourierTagSource.for_viewer(@post, @user)
      assert_includes buckets[:auto], "a"
      assert_includes buckets[:unsourced], "troll_jail"
      refute_includes buckets[:unsourced], "a"
    end

    should "not leak a private tag back through the unsourced fallback" do
      @post.update!(tag_string: "secret a")
      FourierTagSource.record_partition!(@post, { "creator" => ["secret"], "auto" => ["a"] }, @user)

      # The creator sees it, once, in the bucket that says where it came from.
      mine = FourierTagSource.for_viewer(@post, @user)
      assert_includes mine[:creator], "secret"
      refute_includes mine[:unsourced], "secret"

      # Everyone else sees it nowhere. A private tag has a row; it is simply not
      # a VISIBLE one, and that must not read as "no row, so show it".
      theirs = FourierTagSource.for_viewer(@post, nil)
      assert_empty theirs[:creator]
      refute_includes theirs[:unsourced], "secret"
      assert_empty theirs.values.flatten.grep(/secret/)
    end

    should "keep the unsourced fallback out of the public matrix projection" do
      @post.update!(tag_string: "a troll_jail")
      FourierTagSource.record_partition!(@post, { "auto" => ["a"] }, @user)

      proj = FourierTagSource.matrix_projection(@post)
      refute_includes proj[:tags], "troll_jail"
      assert_includes proj[:tags], "a"
    end
  end
end
