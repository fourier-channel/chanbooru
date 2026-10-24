# frozen_string_literal: true

require "test_helper"

# The creator-prefix list and the lock it drives (operator ruling 2026-10-04):
# "adding or changing a prefix is a config change and not a rebuild."
class CreatorPrefixesTest < ActiveSupport::TestCase
  def write_list(text)
    File.write(@path, text)
    # A same-second rewrite of the same length must still be seen: the stamp
    # carries the inode, so write by rename the way an editor does.
    tmp = "#{@path}.tmp"
    File.write(tmp, text)
    File.rename(tmp, @path)
  end

  LIST = <<~YAML
    editors: [tunnel, sample]
    prefixes:
      - {prefix: 4chan_, provenance: Imageboard/web surface, target_kind: site, target: www.4chan.org, scope: b, d and trash AI threads}
      - {prefix: 41chan_, provenance: Matrix, target_kind: server, target: matrix.41chan.net, scope: Channels joined by the tunnel}
      - {prefix: aichan_, provenance: Discord, target_kind: server, target: AIChan, scope: Channels joined by the tunnel}
  YAML

  setup do
    @dir = Dir.mktmpdir("creator-prefixes")
    @path = File.join(@dir, "creator_prefixes.yml")
    @was = ENV["FOURIER_CREATOR_PREFIXES"]
    ENV["FOURIER_CREATOR_PREFIXES"] = @path
    CreatorPrefixes.reset!
    write_list(LIST)
  end

  teardown do
    ENV["FOURIER_CREATOR_PREFIXES"] = @was
    CreatorPrefixes.reset!
    FileUtils.rm_rf(@dir)
  end

  context "The list" do
    should "look a tag up to its exact provenance and target" do
      entry = CreatorPrefixes.lookup("aichan_selphdestruct")

      assert_equal(["aichan_", "Discord", "server", "AIChan"], [entry.prefix, entry.provenance, entry.target_kind, entry.target])
      assert_equal("Matrix", CreatorPrefixes.lookup("41chan_selphdestruct").provenance)
      assert_equal("www.4chan.org", CreatorPrefixes.lookup("4chan_selphdestruct").target)
    end

    should "not treat a bare prefix or an unlisted one as a creator tag" do
      assert_not(CreatorPrefixes.locked?("aichan_"))
      assert_not(CreatorPrefixes.locked?("matrix_selph"))
      assert_not(CreatorPrefixes.locked?("long_hair"))
    end

    should "pick up an edit to the file without a restart" do
      assert_not(CreatorPrefixes.locked?("newsite_selph"))

      write_list(LIST + "  - {prefix: newsite_, provenance: Web, target_kind: site, target: example.org, scope: all}\n")

      assert(CreatorPrefixes.locked?("newsite_selph"))
    end

    should "fail loudly, naming the file and the fix, when the list is missing or malformed" do
      File.delete(@path)
      error = assert_raises(CreatorPrefixes::ConfigError) { CreatorPrefixes.entries }
      assert_match(/#{Regexp.escape(@path)}.*Fix:/, error.message)

      write_list("prefixes:\n  - {prefix: Bad Prefix}\n")
      assert_raises(CreatorPrefixes::ConfigError) { CreatorPrefixes.entries }

      write_list("prefixes:\n  - {prefix: a_}\n  - {prefix: a_}\n")
      assert_raises(CreatorPrefixes::ConfigError) { CreatorPrefixes.entries }

      write_list("prefixes: [unclosed\n")
      assert_raises(CreatorPrefixes::ConfigError) { CreatorPrefixes.entries }
    end

    should "fail loudly, not crash the page, when the list exists but cannot be read" do
      skip "root reads any file, so an unreadable list cannot be made" if Process.uid.zero?

      # The stat needs only the directory; it is the read that is refused.
      File.chmod(0o000, @path)
      error = assert_raises(CreatorPrefixes::ConfigError) { CreatorPrefixes.entries }
      assert_match(/#{Regexp.escape(@path)}.*EACCES.*Fix:/, error.message)
    ensure
      File.chmod(0o644, @path) if File.exist?(@path)
    end

    should "ship a repo default that matches the operator's three entries" do
      ENV["FOURIER_CREATOR_PREFIXES"] = nil
      CreatorPrefixes.reset!

      assert_equal(%w[4chan_ 41chan_ aichan_], CreatorPrefixes.entries.map(&:prefix))
      assert_equal(%w[tunnel sample], CreatorPrefixes.config[:editors])
    end
  end

  context "The lock on a post's tags" do
    setup do
      @tunnel = create(:user, name: "tunnel")
      @member = create(:user)
      @admin = create(:admin_user)
      @post = as(@tunnel) { create(:post, tag_string: "aichan_selph long_hair") }
    end

    should "let the posting service write a creator tag" do
      assert_equal("aichan_selph long_hair", @post.reload.tag_string)
    end

    should "refuse a member who removes a creator tag, and name the fix" do
      as(@member) { @post.update(tag_string: "long_hair") }

      assert_match(/aichan_selph is a creator tag.*ask an admin/, @post.errors.full_messages.join)
      assert_equal("aichan_selph long_hair", @post.reload.tag_string)
    end

    should "refuse a member who adds one" do
      as(@member) { @post.update(tag_string: "aichan_selph 41chan_someone long_hair") }

      assert(@post.errors[:base].any? { |m| m.include?("41chan_someone") })
      assert_not_includes(@post.reload.tag_array, "41chan_someone")
    end

    should "refuse a member who uploads with one" do
      post = as(@member) { build(:post, tag_string: "4chan_forged solo") }

      assert_not(as(@member) { post.save })
      assert(post.errors[:base].any? { |m| m.include?("4chan_forged") })
    end

    should "leave a member free to edit every other tag" do
      as(@member) { @post.update(tag_string: "aichan_selph long_hair smile") }

      assert_empty(@post.errors[:base])
      assert_includes(@post.reload.tag_array, "smile")
    end

    should "let an admin correct a creator tag" do
      as(@admin) { @post.update(tag_string: "aichan_other long_hair") }

      assert_empty(@post.errors[:base])
      assert_equal("aichan_other long_hair", @post.reload.tag_string)
    end

    should "lock a prefix added to the list while the site runs" do
      as(@member) { @post.update(tag_string: "aichan_selph long_hair newsite_x") }
      assert_includes(@post.reload.tag_array, "newsite_x")

      write_list(LIST + "  - {prefix: newsite_, provenance: Web, target_kind: site, target: example.org, scope: all}\n")
      as(@member) { @post.update(tag_string: "aichan_selph long_hair") }

      assert_includes(@post.reload.tag_array, "newsite_x")
    end

    # Fork: and say so in words. What is wrong with the list (its path on the
    # server, the errno, the fix's command) goes to the log: the refusal
    # reaches Technetium's editor and the posting bot, which relays a
    # refused edit into a room (technetium-81, 2026-10-19).
    should "pause a member's tag edits, never unlock them, when the list cannot be read" do
      Rails.logger.stubs(:error)
      Rails.logger.expects(:error).with { |message, *| message.to_s.include?("the creator-prefix list is broken: ") && message.to_s.include?(@path) && message.to_s.include?("cannot be read") }.at_least_once
      File.delete(@path)
      as(@member) { @post.update(tag_string: "long_hair") }

      words = @post.errors.full_messages.join("\n")
      assert_equal("Tag changes are paused while the creator-prefix list is broken; the server log says what is wrong. The site owner fixes the list, then try again", words)
      assert_not_includes(words, @dir)
      assert_equal("aichan_selph long_hair", @post.reload.tag_string)
    end
  end

  # The names a search hides by (PostQuery#hidden_tags_condition), read per
  # request since 2026-10-24. They were cached on the newest tag id, which
  # missed a tag that committed after a higher id had: ids are handed out at
  # INSERT, not at commit, so two creators' first posts in flight together
  # could leave the lower one's tag out of every search until the next tag.
  context "The hidden tag names" do
    setup do
      write_list(LIST.sub("target: AIChan, scope: Channels joined by the tunnel}", "target: AIChan, scope: Channels joined by the tunnel, visible_to: admins}"))
      @post = as(create(:user, name: "tunnel")) { create(:post, tag_string: "long_hair") }
    end

    should "include a tag that committed under an id below the newest" do
      placeholder = create(:tag)
      low = placeholder.id
      Tag.where(id: low).delete_all
      create(:tag, name: "aichan_b")
      CreatorVisibility.forget!
      assert_equal(["aichan_b"], CreatorPrefixes.hidden_tag_names_for(User.anonymous).grep(/\Aaichan_/), "fixture: primed")
      newest = Tag.maximum(:id)

      create(:tag, id: low, name: "aichan_a")
      @post.update_columns(tag_string: "aichan_a long_hair") # rubocop:disable Rails/SkipsModelValidations
      CreatorVisibility.forget!

      assert_equal(newest, Tag.maximum(:id), "fixture: the newest tag id did not move")
      assert_includes(CreatorPrefixes.hidden_tag_names_for(User.anonymous), "aichan_a")
      assert_not_includes(Post.user_tag_match("", User.anonymous).pluck(:id), @post.id)
    end

    # hidden_for? never takes a bare prefix for a creator tag (lookup's
    # length check); the names a search hides by must not either.
    should "not hide a post tagged with the bare prefix" do
      build(:tag, name: "aichan_").save(validate: false)
      @post.update_columns(tag_string: "aichan_ long_hair") # rubocop:disable Rails/SkipsModelValidations
      CreatorVisibility.forget!

      assert_not(CreatorPrefixes.hidden_for?("aichan_", User.anonymous))
      assert_not_includes(CreatorPrefixes.hidden_tag_names_for(User.anonymous), "aichan_")
      assert_includes(Post.user_tag_match("", User.anonymous).pluck(:id), @post.id)
    end
  end
end
