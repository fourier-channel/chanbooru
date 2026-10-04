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

    should "pause a member's tag edits, never unlock them, when the list cannot be read" do
      File.delete(@path)
      as(@member) { @post.update(tag_string: "long_hair") }

      assert_match(/Tag changes are paused: .*cannot be read/, @post.errors.full_messages.join)
      assert_equal("aichan_selph long_hair", @post.reload.tag_string)
    end
  end
end
