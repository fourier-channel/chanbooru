require "test_helper"
require "open3"

# The host image directory is trusted only because bin/chanbooru-storage
# installed it (installed-locations audit 2026-10-04, docker-compose.yaml:159
# and :237). Before: the production compose file bind-mounted it in short
# syntax, so Docker made a missing path as an empty root-owned directory, and
# bin/chanbooru-deploy checked nothing about it -- an unmounted storage drive
# came up as a booru serving nothing, every deploy check green.
#
# Proven here, against directories this test makes:
#   - compose refuses a missing path (long syntax, create_host_path: false),
#     on every service that mounts /images, at the path the script installs;
#   - the check refuses missing, symlink, not-a-directory, root filesystem,
#     wrong owner and group-writable, each with a FAIL line and a fix line;
#   - the install refuses to make its directory on the root filesystem or to
#     make the drive's mountpoint, and otherwise makes it with owner and mode;
#   - the deploy runs the check before it builds or restarts anything.
class ChanbooruImageStorageTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("bin/chanbooru-storage").to_s
  COMPOSE = Rails.root.join("docker-compose.yaml").to_s
  DEPLOY = Rails.root.join("bin/chanbooru-deploy").to_s

  # [exit status, stdout, stderr] of a function in the sourced script. $0 is
  # "bash", not the script: the script runs its CLI when $0 is itself.
  def storage(function, *args)
    out, err, st = Open3.capture3("bash", "-c", 'source "$1"; fn=$2; shift 2; "$fn" "$@"', "bash", SCRIPT, function.to_s, *args.map(&:to_s))
    [st.exitstatus, out, err]
  end

  def mount_of(path)
    Open3.capture3("findmnt", "-n", "-o", "TARGET", "-T", path.to_s).first.strip
  end

  def script_constant(name)
    out, _err, st = Open3.capture3("bash", "-c", 'source "$1"; printf %s "${!2}"', "bash", SCRIPT, name)
    assert st.success?, "could not source #{SCRIPT}"
    out
  end

  # A scratch directory on a filesystem that is NOT the root one (the dev
  # stack mounts tmp/ as tmpfs), and one that IS. Asserted rather than
  # assumed: a test that silently ran both cases on the same filesystem would
  # prove nothing about the mount check.
  def off_root_dir
    base = Rails.root.join("tmp").to_s
    refute_equal "/", mount_of(base), "#{base} must be its own mount for this test (the dev stack makes it tmpfs)"
    Dir.mktmpdir("images-", base)
  end

  def on_root_dir
    base = "/var/tmp"
    assert_equal "/", mount_of(base), "#{base} must be on the root filesystem for this test"
    Dir.mktmpdir("images-", base)
  end

  context "the production compose file" do
    should "bind every /images mount from the installed path, and never create a missing one" do
      compose = YAML.load_file(COMPOSE, aliases: true)
      images_dir = script_constant("IMAGES_DIR")
      assert_equal "/mnt/storage/danbooru-images", images_dir

      mounts = compose["services"].to_h.flat_map do |name, service|
        Array(service["volumes"]).filter_map do |v|
          target = v.is_a?(Hash) ? v["target"] : v.to_s.split(":")[1]
          [name, v] if target == "/images"
        end
      end

      assert_equal %w[cron danbooru jobs nginx], mounts.map(&:first).sort
      mounts.each do |name, v|
        assert_kind_of Hash, v, "#{name}: short-syntax mount #{v.inspect} creates a missing host path"
        assert_equal "bind", v["type"], name
        assert_equal images_dir, v["source"], name
        assert_equal false, v.dig("bind", "create_host_path"), "#{name}: create_host_path must be false"
      end
    end
  end

  context "the image directory check" do
    setup do
      @base = off_root_dir
      @dir = File.join(@base, "images")
      Dir.mkdir(@dir)
      File.chmod(0o755, @dir)
      @uid = Process.uid
    end

    teardown do
      FileUtils.rm_rf(@base)
    end

    should "accept the installed directory" do
      status, _out, err = storage(:check_images_dir, @dir, @uid)
      assert_equal 0, status, err
      assert_empty err
    end

    should "refuse a missing directory, naming it and the install step" do
      missing = File.join(@base, "nope")
      status, _out, err = storage(:check_images_dir, missing, @uid)
      assert_equal 1, status
      assert_match(/^FAIL: #{Regexp.escape(missing)} does not exist/, err)
      assert_match(%r{^fix:\s+.*sudo bin/chanbooru-storage install}, err)
      refute File.exist?(missing), "the check must never create what it checks"
    end

    should "refuse a symlink, even to a good directory" do
      link = File.join(@base, "link")
      File.symlink(@dir, link)
      status, _out, err = storage(:check_images_dir, link, @uid)
      assert_equal 1, status
      assert_match(/^FAIL: .*is a symlink/, err)
      assert_match(/^fix:\s+/, err)
    end

    should "refuse a file that is not a directory" do
      file = File.join(@base, "file")
      File.write(file, "")
      status, _out, err = storage(:check_images_dir, file, @uid)
      assert_equal 1, status
      assert_match(/^FAIL: .*is not a directory/, err)
    end

    should "refuse a directory on the root filesystem: the drive is not mounted" do
      root_base = on_root_dir
      dir = File.join(root_base, "images")
      Dir.mkdir(dir)
      File.chmod(0o755, dir)
      status, _out, err = storage(:check_images_dir, dir, @uid)
      assert_equal 1, status
      assert_match(/^FAIL: .*is on the root filesystem/, err)
      assert_match(/^fix:\s+mount the storage drive/, err)
    ensure
      FileUtils.rm_rf(root_base) if root_base
    end

    should "refuse a directory owned by anyone but the containers' user" do
      status, _out, err = storage(:check_images_dir, @dir, @uid + 1)
      assert_equal 1, status
      assert_match(/^FAIL: .*is owned by uid #{@uid}, not #{@uid + 1}/, err)
      assert_match(%r{^fix:\s+sudo bin/chanbooru-storage install}, err)
    end

    should "refuse a directory writable by group or other" do
      [0o775, 0o757, 0o777].each do |mode|
        File.chmod(mode, @dir)
        status, _out, err = storage(:check_images_dir, @dir, @uid)
        assert_equal 1, status, format("%o", mode)
        assert_match(/^FAIL: .*is mode #{format("%o", mode)}: writable by group or other/, err)
      end
    end

    should "refuse from the command line too, with the absolute production path" do
      # The dev container has no /mnt/storage: the CLI must say so, not make it.
      refute File.exist?("/mnt/storage/danbooru-images"), "this proves the refusal, so it needs a box without the production directory"

      out, err, st = Open3.capture3(SCRIPT, "check")
      assert_equal 1, st.exitstatus, out
      assert_match(%r{^FAIL: /mnt/storage/danbooru-images does not exist}, err)
      assert_match(/^fix:\s+/, err)
      refute File.exist?("/mnt/storage/danbooru-images")
    end
  end

  context "the image directory install" do
    setup do
      @base = off_root_dir
      @uid = Process.uid
      @gid = Process.gid
    end

    teardown do
      FileUtils.rm_rf(@base)
    end

    should "make the directory with its owner and mode, and pass the check" do
      dir = File.join(@base, "images")
      status, out, err = storage(:install_images_dir, dir, @uid, @gid, 755)
      assert_equal 0, status, err
      assert_match(/^created #{Regexp.escape(dir)}/, out)
      stat = File.lstat(dir)
      assert stat.directory?
      assert_equal 0o755, stat.mode & 0o777
      assert_equal @uid, stat.uid
    end

    should "tighten an existing group-writable directory without touching its contents" do
      dir = File.join(@base, "images")
      Dir.mkdir(dir)
      File.write(File.join(dir, "keep.jpg"), "x")
      File.chmod(0o775, dir)
      status, out, err = storage(:install_images_dir, dir, @uid, @gid, 755)
      assert_equal 0, status, err
      refute_match(/^created/, out)
      assert_equal 0o755, File.stat(dir).mode & 0o777
      assert_equal "x", File.read(File.join(dir, "keep.jpg"))
    end

    should "refuse to make the drive's mountpoint" do
      dir = File.join(@base, "not-mounted", "images")
      status, _out, err = storage(:install_images_dir, dir, @uid, @gid, 755)
      assert_equal 1, status
      assert_match(/^FAIL: .*not-mounted does not exist/, err)
      assert_match(/^fix:\s+mount the storage drive/, err)
      refute File.exist?(File.dirname(dir))
    end

    should "refuse to make the directory on the root filesystem" do
      root_base = on_root_dir
      dir = File.join(root_base, "images")
      status, _out, err = storage(:install_images_dir, dir, @uid, @gid, 755)
      assert_equal 1, status
      assert_match(/^FAIL: .*is on the root filesystem/, err)
      refute File.exist?(dir), "install must not make the directory on the root disk"
    ensure
      FileUtils.rm_rf(root_base) if root_base
    end

    should "refuse to adopt a symlink" do
      target = File.join(@base, "elsewhere")
      Dir.mkdir(target)
      dir = File.join(@base, "images")
      File.symlink(target, dir)
      status, _out, err = storage(:install_images_dir, dir, @uid, @gid, 755)
      assert_equal 1, status
      assert_match(/^FAIL: .*is a symlink/, err)
    end
  end

  context "the deploy" do
    should "check the image directory before it builds or restarts anything" do
      deploy = File.read(DEPLOY)
      check = deploy.index(%(bin/chanbooru-storage check || die))
      assert check, "bin/chanbooru-deploy must run bin/chanbooru-storage check and die on refusal"
      assert_operator check, :<, deploy.index("bin/build-docker-image danbooru"), "the check must come before the build"
      assert_operator check, :<, deploy.index("docker compose --progress quiet up -d"), "the check must come before compose up"
    end
  end
end
