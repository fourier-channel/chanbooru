# frozen_string_literal: true

require "test_helper"

# A creator's claim on an original character's tag (OC ownership, ruled
# 2026-10-11): the tag is <name>_(<the creator's own name>), kept by name,
# approved on filing (operator, 2026-11-05), and every decision logged. It confers rights over the character's wiki page and
# category, never over who sees posts.
class CharacterClaimTest < ActiveSupport::TestCase
  def gallery_for(user, slug)
    CreatorGallery.create!(matrix_id: "@#{slug}:41chan.net", slug: slug, user: user)
  end

  def refusal(name, gallery = @gallery)
    CharacterClaim.refusal(name, gallery&.slug)
  end

  setup do
    CreatorPrefixes.reset!
    @saber = create(:user)
    @gallery = gallery_for(@saber, "saber")
    @admin = create(:admin_user)
  end

  context "the naming rule" do
    should "accept the creator's own name in brackets, in any case" do
      assert_nil(refusal("maple_(saber)"))
      assert_nil(refusal("maple_(SABER)"))
    end

    should "refuse every other shape, each with the name it should have been" do
      {
        "maple" => "claim it as maple_(saber), your name in brackets",
        "_(saber)" => "is not an original character's tag",
        "maple_(bob)" => "maple_(bob) names bob: claim maple_(saber)",
        "41chan_maple_(saber)" => "41chan_ marks creator tags, not characters: claim maple_(saber)",
        "4chan_saber" => "is not an original character's tag",
        "maple_(a_(saber))" => "is not an original character's tag",
        "maple__(saber)" => "consecutive underscores",
        "maple)" => "maple) is not an original character's tag: claim it as maple_(saber), your name in brackets",
      }.each do |name, words|
        assert_includes(refusal(name).to_s, words, name)
      end
    end

    # Upstream gives <x>_(cosplay), _(meme) and an artist's _(style) a
    # meaning, and TagMover carries <x>_(cosplay) along when <x> is aliased
    # or renamed, so a claim under one would move with no check on it.
    should "refuse a qualifier the booru reserves, and never let a stored one stand" do
      cosplay = gallery_for(create(:user), "cosplay")

      assert_includes(refusal("fir_(cosplay)", cosplay), "the booru gives every tag ending _(cosplay) a meaning of its own")
      assert_includes(refusal("fir_(style)", gallery_for(create(:user), "style")).to_s, "_(style) a meaning of its own")

      stored = CharacterClaim.new(creator_gallery: cosplay, tag_name: "fir_(cosplay)", status: CharacterClaim::APPROVED)
      stored.save!(validate: false)
      assert_not(CharacterClaim.claimed?(["fir_(cosplay)"]))
    end

    should "refuse a tag filed as anything but general or character" do
      create(:tag, name: "maple_(saber)", category: TagCategory::COPYRIGHT)

      assert_includes(refusal("maple_(saber)"), "maple_(saber) is filed as copyright: ask an admin to re-file it as a character first")
    end

    should "refuse an alias antecedent, naming where it points" do
      create(:tag_alias, antecedent_name: "maple_(saber)", consequent_name: "maple_leaf_(saber)")

      assert_includes(refusal("maple_(saber)"), "maple_(saber) is aliased to maple_leaf_(saber): claim maple_leaf_(saber), or ask an admin to remove the alias")
    end

    context "with a broken prefix list" do
      setup do
        @dir = Dir.mktmpdir("character-claim-prefixes")
        @path = File.join(@dir, "creator_prefixes.yml")
        @was = ENV.fetch("FOURIER_CREATOR_PREFIXES", nil)
        File.write(@path, "prefixes: [unclosed\n")
        ENV["FOURIER_CREATOR_PREFIXES"] = @path
        CreatorPrefixes.reset!
      end

      teardown do
        ENV["FOURIER_CREATOR_PREFIXES"] = @was
        CreatorPrefixes.reset!
        FileUtils.rm_rf(@dir)
      end

      should "refuse the filing rather than pass it" do
        claim = CharacterClaim.new(creator_gallery: @gallery, tag_name: "maple_(saber)")

        assert_not(claim.valid?)
        assert_includes(claim.errors.full_messages.join, "cannot be checked while the creator-prefix list is broken")
      end

      # Fork: what is wrong with the list (its path on the server, the
      # parser's words) goes to the log; the refusal is words only. It
      # reaches a bulk update request's run record, which every reader sees
      # and a bot relays into a room (technetium-81, 2026-10-19).
      should "keep the list's path and the parser's words out of the refusal, and log them" do
        Rails.logger.stubs(:error)
        Rails.logger.expects(:error).with { |message, *| message.to_s.include?("the creator-prefix list is broken: ") && message.to_s.include?(@path) }.at_least_once
        claim = CharacterClaim.new(creator_gallery: @gallery, tag_name: "maple_(saber)")
        claim.valid?
        words = claim.errors.full_messages.join("\n")

        assert_not_includes(words, @dir)
        assert_no_match(/YAML|Psych|unclosed/i, words)
        assert_match(/the server log says what is wrong/, words)
      end

      should "keep them out of a move's refusal too" do
        Rails.logger.stubs(:error)
        Rails.logger.expects(:error).with { |message, *| message.to_s.include?("the creator-prefix list is broken: ") && message.to_s.include?(@path) }.at_least_once
        why = CharacterClaim.move_refusal("oc_maple", "maple_(saber)")

        assert_match(/\Aoc_maple -> maple_\(saber\): its ownership cannot be checked while the creator-prefix list is broken/, why)
        assert_not_includes(why, @dir)
        assert_no_match(/YAML|Psych|unclosed/i, why)
        assert_match(/the server log says what is wrong/, why)
      end
    end
  end

  context "prepare" do
    should "complete a bare name with the creator's own" do
      claim, refused = CharacterClaim.prepare(@gallery, @saber, " Maple Leaf ")

      assert_nil(refused)
      assert_equal("maple_leaf_(saber)", claim.tag_name)
    end

    should "refuse an anonymous, an unlinked and a banned account in ArtistClaim's words" do
      assert_match(/Link this page to your booru account/, CharacterClaim.prepare(@gallery, User.anonymous, "maple").second)
      assert_match(/Link this page to your booru account/, CharacterClaim.prepare(@gallery, create(:user), "maple").second)
      assert_match(/Link this page to your booru account/, CharacterClaim.prepare(gallery_for(nil, "nobody"), @saber, "maple").second)

      as(@admin) { create(:ban, user: @saber, banner: @admin) }
      assert_match(/A banned account cannot claim/, CharacterClaim.prepare(@gallery, @saber.reload, "maple").second)
    end
  end

  context "filing" do
    should "approve a clean name at once, creating the tag as a character that implies original" do
      claim = CharacterClaim.prepare(@gallery, @saber, "maple").first

      assert_equal([], claim.file!)
      assert(claim.reload.approved?)
      assert(Tag.find_by_name("maple_(saber)").character?)
      assert(TagImplication.active.exists?(antecedent_name: "maple_(saber)", consequent_name: "original"))
      assert(Tag.find_by_name("original").copyright?, "original stays copyright after the implication")
      action = ModAction.find_by!(category: "character_claim_approve")
      assert_equal(Tag.find_by_name("maple_(saber)"), action.subject)
      assert_equal(User.system, action.creator)
      assert_match(/automatically/, action.description)
    end

    # Operator, 2026-11-05: the name in brackets is the creator's own, so a
    # name already in use is theirs at once too; the log says what it carried.
    should "approve at once a name with posts, a wiki page or an alias, and log what it carried" do
      as(@admin) { create(:post, tag_string: "maple_(saber)") }
      as(@admin) { create(:wiki_page, title: "pine_(saber)") }
      create(:tag_alias, antecedent_name: "fir_(other)", consequent_name: "fir_(saber)")

      { "maple" => "it is on 1 post", "pine" => "it has a wiki page", "fir" => "fir_(other) is aliased to it" }.each do |name, carried|
        claim = CharacterClaim.prepare(@gallery, @saber, name).first

        assert_equal([], claim.file!, name)
        assert(claim.reload.approved?, name)
        assert_includes(ModAction.where(category: "character_claim_approve").last.description, "(#{carried})", name)
      end
      assert(Tag.find_by_name("maple_(saber)").character?, "the posted tag is re-filed as a character")
    end

    should "wait for an admin when approving it fails, saying why" do
      Tag.any_instance.stubs(:update).returns(false)
      as(@admin) { create(:post, tag_string: "maple_(saber)") }
      claim = CharacterClaim.prepare(@gallery, @saber, "maple").first

      assert_match(/could not be approved automatically: .*could not be re-filed as a character/, claim.file!.sole)
      assert(claim.reload.pending?)
    end

    should "tell a creator re-filing a character they already hold, in one sentence, that it is theirs" do
      CharacterClaim.prepare(@gallery, @saber, "maple").first.file!

      _claim, refusal = CharacterClaim.prepare(@gallery, @saber, "maple")
      assert_equal("maple_(saber) is already yours by an approved claim: nothing to file", refusal)
    end

    should "allow one open claim per gallery per tag" do
      CharacterClaim.prepare(@gallery, @saber, "maple").first.save!

      again = CharacterClaim.new(creator_gallery: @gallery, tag_name: "maple_(saber)")
      assert_not(again.valid?)
      assert_includes(again.errors.full_messages.join, "already waiting for an admin")
    end
  end

  # A pending claim: one whose automatic approval failed, or a held one its
  # gallery could not approve when it came (take_up_held!).
  context "deciding" do
    setup do
      as(@admin) { create(:post, tag_string: "maple_(saber)") }
      @claim = CharacterClaim.prepare(@gallery, @saber, "maple").first
      @claim.save!
    end

    should "refuse an approval or rejection by anyone but an admin" do
      [create(:moderator_user), @saber, User.anonymous, nil].each do |user|
        assert_raises(User::PrivilegeError, user&.name.inspect) { @claim.approve!(by: user) }
        assert_raises(User::PrivilegeError, user&.name.inspect) { @claim.reject!(by: user, note: "no") }
      end
      assert(@claim.reload.pending?)
    end

    should "re-file a general tag with posts as a character on an admin's approval, imply original, and log it" do
      @claim.approve!(by: @admin)

      tag = Tag.find_by_name("maple_(saber)")
      assert(tag.character?)
      assert(@claim.reload.approved?)
      assert_equal(@admin, @claim.approver)
      assert(TagImplication.active.exists?(antecedent_name: "maple_(saber)", consequent_name: "original"))
      assert(Tag.find_by_name("original").copyright?)
      assert(Post.last.reload.has_tag?("original"), "the implication reaches the posts already tagged")
      action = ModAction.find_by!(category: "character_claim_approve")
      assert_equal([tag, @admin], [action.subject, action.creator])
      assert_match(/@saber/, action.description)
      assert_no_match(/41chan\.net/, action.description)
    end

    should "refuse to approve when the tag could not be re-filed as a character, and change nothing" do
      Tag.any_instance.stubs(:update).returns(false)

      error = assert_raises(ActiveRecord::RecordInvalid) { @claim.approve!(by: @admin) }
      assert_match(/is filed as general and could not be re-filed as a character/, error.message)
      assert(@claim.reload.pending?)
      assert_equal(0, TagImplication.count)
    end

    should "log a rejection and a withdrawal under one category" do
      @claim.reject!(by: @admin, note: "series name")
      assert(@claim.reload.rejected?)

      other = CharacterClaim.prepare(@gallery, @saber, "maple").first
      other.save!
      other.approve!(by: @admin)
      other.reject!(by: @admin, note: "approval withdrawn")

      assert_equal(2, ModAction.where(category: "character_claim_reject").count)
      assert_equal(%w[1116 1117], [ModAction.categories["character_claim_approve"], ModAction.categories["character_claim_reject"]].map(&:to_s))
    end

    should "keep one approved claim per tag, by validation and at the index" do
      @claim.approve!(by: @admin)
      # Another gallery's: the holder's own second filing is told it is theirs.
      rival = CharacterClaim.new(creator_gallery: gallery_for(create(:user), "bob"), tag_name: "maple_(saber)", status: CharacterClaim::APPROVED)

      assert_not(rival.valid?)
      assert_includes(rival.errors.full_messages.join, "already has an approved claim")
      assert_raises(ActiveRecord::RecordNotUnique) { rival.save!(validate: false) }
    end
  end

  context "an approved claim" do
    setup do
      @claim = CharacterClaim.prepare(@gallery, @saber, "maple").first
      @claim.file!
    end

    should "make its creator the keeper of the name's wiki page, and nobody else" do
      wiki = WikiPage.new(title: "maple_(saber)")

      assert(CharacterClaim.claimed?(["maple_(saber)"]))
      assert_not(CharacterClaim.claimed?(["pine_(saber)"]))
      assert(WikiPagePolicy.new(@saber, wiki).create?)
      assert_not(WikiPagePolicy.new(create(:user), wiki).create?)
      assert_not(WikiPagePolicy.new(User.anonymous, wiki).create?)
    end

    should "stop conferring when the gallery is unlinked or its account banned, and come back on re-link" do
      wiki = WikiPage.new(title: "maple_(saber)")
      @gallery.update!(user: nil)
      assert_not(WikiPagePolicy.new(@saber, wiki).create?)
      assert(CharacterClaim.claimed?(["maple_(saber)"]), "the mark stays")

      @gallery.update!(user: @saber)
      assert(WikiPagePolicy.new(@saber, wiki).create?)

      as(@admin) { create(:ban, user: @saber, banner: @admin) }
      assert_not(WikiPagePolicy.new(@saber.reload, wiki).create?)
    end

    should "stop standing when an alias is made from it outside a request" do
      create(:tag_alias, antecedent_name: "maple_(saber)", consequent_name: "maple_leaf")

      assert_not(CharacterClaim.claimed?(["maple_(saber)"]))
    end

    should "be released by its creator only, leaving the tag, its wiki and the implication in place" do
      as(@saber) { create(:wiki_page, title: "maple_(saber)", body: "mine") }
      assert_raises(User::PrivilegeError) { @claim.release!(by: create(:user)) }
      assert_raises(User::PrivilegeError) { @claim.release!(by: @admin) }

      @claim.release!(by: @saber)

      assert(@claim.reload.released?)
      assert_not(CharacterClaim.claimed?(["maple_(saber)"]))
      assert(Tag.find_by_name("maple_(saber)").character?)
      assert(WikiPage.find_by(title: "maple_(saber)").present?)
      assert(TagImplication.active.exists?(antecedent_name: "maple_(saber)", consequent_name: "original"))
      action = ModAction.find_by!(category: "character_claim_release")
      assert_equal([Tag.find_by_name("maple_(saber)"), @saber], [action.subject, action.creator])
      assert_equal(1118, ModAction.categories["character_claim_release"])
    end

    should "confer no control over who sees another member's post carrying the tag" do
      post = as(@admin) { create(:post, tag_string: "maple_(saber)") }

      assert_equal([], CreatorControl.controller_gallery_ids([post]).fetch(post.id))
    end

    context "under a changed prefix list" do
      setup do
        @dir = Dir.mktmpdir("character-claim-prefixes")
        @path = File.join(@dir, "creator_prefixes.yml")
        @was = ENV.fetch("FOURIER_CREATOR_PREFIXES", nil)
        File.write(@path, File.read(CreatorPrefixes::DEFAULT_PATH))
        ENV["FOURIER_CREATOR_PREFIXES"] = @path
        CreatorPrefixes.reset!
      end

      teardown do
        ENV["FOURIER_CREATOR_PREFIXES"] = @was
        CreatorPrefixes.reset!
        FileUtils.rm_rf(@dir)
      end

      should "stop standing once a listed prefix covers the name" do
        File.write(@path, <<~YAML)
          editors: [tunnel]
          prefixes:
            - {prefix: maple_, provenance: Web, target_kind: site, target: example.org, scope: x}
        YAML
        CreatorPrefixes.reset!

        assert_not(CharacterClaim.claimed?(["maple_(saber)"]))
      end

      should "keep standing while the prefix file is broken" do
        assert(CharacterClaim.claimed?(["maple_(saber)"])) # the good list is read, and kept as the last good one
        File.write(@path, "prefixes: [unclosed\n")
        assert_raises(CreatorPrefixes::ConfigError) { CreatorPrefixes.entries }

        assert(CharacterClaim.claimed?(["maple_(saber)"]))
      end
    end
  end

  # Operator, 2026-11-05: "if the currently tagged character's creator
  # matches their usernames, it also says available for immediate claim".
  context "under one of the gallery's creator names" do
    setup do
      @maple = ArtistClaim.create!(artist: create(:artist, name: "4chan_maple"), creator_gallery: @gallery, by_review: true)
      @maple.approve!(by: @admin)
    end

    should "be claimable, and stand, while the creator name does" do
      claim, refusal = CharacterClaim.prepare(@gallery, @saber, "pine_(maple)")

      assert_nil(refusal)
      assert_equal([], claim.file!)
      assert(CharacterClaim.claimed?(["pine_(maple)"]))

      @maple.reject!(by: @admin, note: "approval withdrawn")
      assert_not(CharacterClaim.claimed?(["pine_(maple)"]), "the creator name gone, the character no longer stands")
    end

    should "not be a name a claim is pending on, or someone else's" do
      ArtistClaim.create!(artist: create(:artist, name: "4chan_fern"), creator_gallery: @gallery, by_review: true)

      assert_match(/pine_\(fern\) names fern: claim pine_\(saber\)/, CharacterClaim.prepare(@gallery, @saber, "pine_(fern)").second)
      assert_match(/names maple/, CharacterClaim.prepare(gallery_for(create(:user), "bob"), User.last, "pine_(maple)").second)
    end

    should "give way to a gallery whose slug it is" do
      gallery_for(create(:user), "maple")

      assert_equal([], CharacterClaim.creator_names(@gallery.id))
      assert_match(/names maple/, CharacterClaim.prepare(@gallery, @saber, "pine_(maple)").second)
    end

    should "let the creator take up a character held for that name" do
      held = CharacterClaim.create!(tag_name: "kayla_(maple)", creator_slug: "maple", status: CharacterClaim::HELD, approver: @admin, note: "held for @maple")

      assert_equal([held], CharacterClaim.held_for(@gallery).to_a)
      assert_raises(User::PrivilegeError) { held.take_up!(@gallery, by: create(:user)) }

      held.take_up!(@gallery, by: @saber)
      assert_equal([CharacterClaim::APPROVED, @gallery.id, @admin.id], [held.reload.status, held.creator_gallery_id, held.approver_id])
      assert(CharacterClaim.claimed?(["kayla_(maple)"]))
      assert_match(/taken up by @saber, whose creator name is maple/, ModAction.where(category: "character_claim_approve").last.description)
      assert_raises(ActiveRecord::RecordInvalid) { held.take_up!(@gallery, by: @saber) }
    end

    # The Identity dashboard's "available for immediate claim" list.
    should "offer the characters already tagged under the creator's names that nobody claims" do
      as(@admin) do
        create(:post, tag_string: "pine_(maple) fern_(saber) rose_(bob) oak_(maple) rock_(maple)")
        create(:post, tag_string: "pine_(maple)")
      end
      Tag.find_by_name("rock_(maple)").update!(category: TagCategory::COPYRIGHT, updater: @admin)
      CharacterClaim.create!(tag_name: "oak_(maple)", creator_slug: "maple", status: CharacterClaim::HELD, approver: @admin)

      ready = CharacterClaim.ready_for(@gallery, @saber)

      assert_equal(%w[pine_(maple) fern_(saber)], ready, "most used first; never another creator's, a held one or one the rule refuses")
      CharacterClaim.prepare(@gallery, @saber, "pine_(maple)").first.file!
      assert_equal(["fern_(saber)"], CharacterClaim.ready_for(@gallery, @saber), "a claimed name leaves the list")
    end
  end
end
