# frozen_string_literal: true

require "test_helper"

# Who controls a post (design CREATOR_VISIBILITY sections 3 and 9, ruled
# 2026-10-07): the recorded creator when there is one; otherwise the approved
# claimant of a locked creator tag the post carries, or -- with no claim at
# all -- the Matrix account a master-prefix tag names (Q6: "41chan_<self>
# needs no claim"). Never a TagGrant: a moderator issues those (Q2). Every case
# is asked from both ends -- the post's and the user's -- because enforcement
# will use the batch form and the two must never disagree.
class CreatorControlTest < ActiveSupport::TestCase
  def gallery_for(user, mxid)
    CreatorGallery.create!(matrix_id: mxid, slug: mxid.gsub(/[^a-z0-9]/, "-"), user: user)
  end

  def post_tagged(tags, creator: nil)
    post = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: tags) }
    FourierPostCreator.create!(post: post, mxid: creator, recorded_by: @tunnel.id) if creator
    post
  end

  def approved_claim(gallery, tag)
    artist = Artist.find_by(name: tag) || as(@admin) { create(:artist, name: tag) }
    ArtistClaim.create!(artist: artist, creator_gallery: gallery).tap { |c| c.approve!(by: @admin) }
  end

  # The batch answer from the user's end must equal the per-post answer from
  # the post's end, row for row, over every post the test made.
  def assert_agrees(user, posts)
    by_post = posts.select { |p| CreatorControl.controls?(user, p) }.map(&:id).sort
    by_user = CreatorControl.controlled_post_ids(user) & posts.map(&:id)

    assert_equal(by_post, by_user, "controlled_post_ids(#{user&.name.inspect}) disagrees with controls?")
  end

  setup do
    @tunnel = create(:builder_user, name: "tunnel")
    @admin = create(:admin_user)
    @maple = create(:user)
    @alice = create(:user)
    @maple_gallery = gallery_for(@maple, "@maple:41chan.net")
    @alice_gallery = gallery_for(@alice, "@alice:41chan.net")
  end

  context "the recorded creator" do
    should "control their post, matched case-insensitively, and nobody else does" do
      post = post_tagged("landscape", creator: "@Alice:41chan.net")

      assert(CreatorControl.controls?(@alice, post))
      assert_not(CreatorControl.controls?(@maple, post))
      assert_equal([@alice_gallery.id], CreatorControl.controller_gallery_ids([post])[post.id])
      assert_includes(CreatorControl.controlled_post_ids(@alice), post.id)
      assert_agrees(@maple, [post])
    end

    # One controller per post (section 9): an approved claim on another tag the
    # post carries does not add a second.
    should "outrank an approved claimant of a creator tag on the same post" do
      approved_claim(@maple_gallery, "4chan_maple")
      post = post_tagged("4chan_maple 41chan_maple landscape", creator: "@alice:41chan.net")

      assert(CreatorControl.controls?(@alice, post))
      assert_not(CreatorControl.controls?(@maple, post))
      assert_agrees(@maple, [post])
      assert_agrees(@alice, [post])
    end

    should "leave the post uncontrolled by any account when their gallery is not linked" do
      unlinked = gallery_for(nil, "@nobody:41chan.net")
      post = post_tagged("landscape", creator: "@nobody:41chan.net")

      assert_equal([unlinked.id], CreatorControl.controller_gallery_ids([post])[post.id])
      assert_equal({ post.id => [] }, CreatorControl.controller_user_ids([post]))
    end
  end

  context "an approved claim" do
    should "confer control of posts carrying the claimed tag" do
      approved_claim(@maple_gallery, "4chan_maple")
      post = post_tagged("4chan_maple landscape")

      assert(CreatorControl.controls?(@maple, post))
      assert_not(CreatorControl.controls?(@alice, post))
      assert_agrees(@maple, [post])
    end

    should "confer nothing while pending or once rejected" do
      artist = as(@admin) { create(:artist, name: "4chan_maple") }
      ArtistClaim.create!(artist: artist, creator_gallery: @maple_gallery)
      pending_post = post_tagged("4chan_maple landscape")
      assert_not(CreatorControl.controls?(@maple, pending_post))

      ArtistClaim.pending.sole.reject!(by: @admin)
      assert_not(CreatorControl.controls?(@maple, pending_post))
      assert_agrees(@maple, [pending_post])
    end

    # Renaming an Artist is open to any unbanned member. Control is keyed on
    # the claim's tag_name, fixed at filing, so the rename moves nothing.
    should "not move when the claimed artist is renamed" do
      claim = approved_claim(@maple_gallery, "4chan_maple")
      as(@admin) { claim.artist.update!(name: "4chan_victim") }
      claimed = post_tagged("4chan_maple landscape")
      victim = post_tagged("4chan_victim landscape")

      assert(CreatorControl.controls?(@maple, claimed))
      assert_not(CreatorControl.controls?(@maple, victim))
      assert_agrees(@maple, [claimed, victim])
    end

    # Re-checked at use: a row that no longer satisfies the stripped-name rule
    # (a legacy row, or one written around the model) confers nothing.
    should "confer nothing when its tag does not strip to the claimant's localpart" do
      claim = approved_claim(@maple_gallery, "4chan_maple")
      claim.update_columns(tag_name: "4chan_victim") # rubocop:disable Rails/SkipsModelValidations
      victim = post_tagged("4chan_victim landscape")

      assert_not(CreatorControl.controls?(@maple, victim))
      assert_agrees(@maple, [victim])
    end

    context "whose prefix leaves the live list" do
      setup do
        @dir = Dir.mktmpdir("creator-control-prefixes")
        @path = File.join(@dir, "creator_prefixes.yml")
        @was = ENV.fetch("FOURIER_CREATOR_PREFIXES", nil)
        approved_claim(@maple_gallery, "4chan_maple")
        @post = post_tagged("4chan_maple landscape")
        File.write(@path, <<~YAML)
          editors: [tunnel]
          prefixes:
            - {prefix: 41chan_, provenance: Matrix, target_kind: server, target: matrix.41chan.net, scope: x}
        YAML
        ENV["FOURIER_CREATOR_PREFIXES"] = @path
        CreatorPrefixes.reset!
      end

      teardown do
        ENV["FOURIER_CREATOR_PREFIXES"] = @was
        CreatorPrefixes.reset!
        FileUtils.rm_rf(@dir)
      end

      # An unlocked tag is one any member can put on any post.
      should "confer nothing" do
        assert_not(CreatorControl.controls?(@maple, @post))
        assert_agrees(@maple, [@post])
      end
    end
  end

  context "a master-prefix tag" do
    should "confer control on the Matrix account it names, with no claim" do
      post = post_tagged("41chan_maple landscape")

      assert(CreatorControl.controls?(@maple, post))
      assert_not(CreatorControl.controls?(@alice, post))
      assert_equal(0, ArtistClaim.count)
      assert_agrees(@maple, [post])
    end

    # The master tag names an account on THIS homeserver
    # (FourierCreatorPrivacy.mxid_for_poster_tag); a same-localpart account
    # elsewhere is someone else.
    should "not confer control on a same-localpart account on another server" do
      stranger = create(:user)
      gallery_for(stranger, "@maple:other.example")
      post = post_tagged("41chan_maple landscape")

      assert_not(CreatorControl.controls?(stranger, post))
      assert_agrees(stranger, [post])
    end
  end

  context "a TagGrant" do
    # Q2 and section 9: ownership never reads TagGrant -- any moderator can
    # issue one, to anyone, themselves included.
    should "confer no control, of any ability, on any tag the post carries" do
      moderator = create(:moderator_user)
      post = post_tagged("4chan_maple 41chan_maple landscape")
      TagGrant::ABILITIES.each do |ability|
        %w[4chan_maple 41chan_maple landscape].each do |tag|
          TagGrant.new(user: moderator, tag: tag, ability: ability, granted_by: moderator.id).save!(validate: false)
        end
      end

      assert_not(CreatorControl.controls?(moderator, post))
      assert_empty(CreatorControl.controlled_post_ids(moderator))
    end
  end

  should "answer nothing for a signed-out viewer or nil" do
    post = post_tagged("41chan_maple landscape")

    [User.anonymous, nil].each do |user|
      assert_not(CreatorControl.controls?(user, post))
      assert_empty(CreatorControl.controlled_post_ids(user))
    end
  end

  should "give the same answers in batch as post by post, over every kind of post at once" do
    approved_claim(@maple_gallery, "4chan_maple")
    approved_claim(@alice_gallery, "aichan_alice")
    unlinked = gallery_for(nil, "@nobody:41chan.net")
    posts = [
      post_tagged("landscape", creator: "@alice:41chan.net"),
      post_tagged("4chan_maple landscape", creator: "@ALICE:41chan.net"),
      post_tagged("4chan_maple landscape"),
      post_tagged("4chan_maple aichan_alice landscape"),
      post_tagged("41chan_maple landscape"),
      post_tagged("41chan_alice 4chan_maple landscape"),
      post_tagged("41chan_nobody landscape"),
      post_tagged("landscape", creator: "@nobody:41chan.net"),
      post_tagged("4chan_victim landscape"),
      post_tagged("landscape"),
    ]

    batch = CreatorControl.controller_gallery_ids(posts)
    assert_equal(posts.map(&:id).sort, batch.keys.sort)
    posts.each do |post|
      assert_equal(CreatorControl.controller_gallery_ids([post])[post.id], batch[post.id], "post #{post.tag_string}")
    end

    expected = [
      [@alice_gallery.id], [@alice_gallery.id], [@maple_gallery.id], [@alice_gallery.id, @maple_gallery.id].sort,
      [@maple_gallery.id], [@alice_gallery.id, @maple_gallery.id].sort, [unlinked.id], [unlinked.id], [], [],
    ]
    assert_equal(expected, posts.map { |p| batch[p.id] })

    [@maple, @alice, @admin, @tunnel].each { |user| assert_agrees(user, posts) }
  end
end
