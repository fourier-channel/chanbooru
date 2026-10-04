require "test_helper"
require "open3"

# The deploy's build log was /tmp/chanbooru-build.log: a fixed name in a
# world-writable directory nothing installed, written with `: >` and `tee`, so
# a symlink planted there by any local user was followed -- as root under sudo
# (installed-locations audit 2026-10-04, bin/chanbooru-deploy:23 and :195;
# bin/build-watch:27 read the same path).
#
# Proven here: the log lives in tmp/chanbooru-deploy/ of the checkout, which
# the deploy (its writer) installs at 700 and checks before writing, and
# build-watch (its reader) refuses rather than creates; neither names /tmp.
class ChanbooruBuildLogTest < ActiveSupport::TestCase
  LIB = Rails.root.join("script/chanbooru-build-log.sh").to_s
  DEPLOY = Rails.root.join("bin/chanbooru-deploy").to_s
  WATCH = Rails.root.join("bin/build-watch").to_s

  def lib(function, *args)
    out, err, st = Open3.capture3("bash", "-c", 'source "$1"; fn=$2; shift 2; "$fn" "$@"', "bash", LIB, function.to_s, *args.map(&:to_s))
    [st.exitstatus, out, err]
  end

  setup do
    @base = Dir.mktmpdir("buildlog-", Rails.root.join("tmp").to_s)
    @uid = Process.uid
  end

  teardown do
    FileUtils.rm_rf(@base)
  end

  context "the build log location" do
    should "be tmp/chanbooru-deploy in the checkout, and named by neither script as /tmp" do
      status, out, _err = lib(:build_log_dir, "/opt/danbooru")
      assert_equal 0, status
      assert_equal "/opt/danbooru/tmp/chanbooru-deploy", out

      [DEPLOY, WATCH].each do |path|
        refute_includes File.read(path), "/tmp/chanbooru-build.log", path
      end
    end
  end

  context "the deploy's install of the log directory" do
    should "make it at mode 700 when missing, and tighten one of ours" do
      dir = File.join(@base, "tmp", "chanbooru-deploy")
      status, _out, err = lib(:install_build_log_dir, dir, @uid)
      assert_equal 0, status, err
      assert_equal 0o700, File.lstat(dir).mode & 0o777

      File.chmod(0o777, dir)
      status, _out, err = lib(:install_build_log_dir, dir, @uid)
      assert_equal 0, status, err
      assert_equal 0o700, File.lstat(dir).mode & 0o777
    end

    should "refuse a symlinked directory, a directory owned by someone else, and a planted link to the log" do
      target = File.join(@base, "elsewhere")
      Dir.mkdir(target)
      link = File.join(@base, "linked")
      File.symlink(target, link)
      status, _out, err = lib(:install_build_log_dir, link, @uid)
      assert_equal 1, status
      assert_match(/^FAIL: .*is a symlink/, err)
      assert_match(/^fix:\s+/, err)

      dir = File.join(@base, "owned")
      Dir.mkdir(dir, 0o700)
      status, _out, err = lib(:install_build_log_dir, dir, @uid + 1)
      assert_equal 1, status
      assert_match(/^FAIL: .*is owned by uid #{@uid}, not uid #{@uid + 1}/, err)

      victim = File.join(@base, "victim")
      File.write(victim, "precious")
      File.symlink(victim, File.join(dir, "build.log"))
      status, _out, err = lib(:install_build_log_dir, dir, @uid)
      assert_equal 1, status
      assert_match(%r{^FAIL: .*/build\.log is a symlink}, err)
      assert_equal "precious", File.read(victim)
    end
  end

  context "the deploy" do
    should "install and check the log directory before its first write to the log" do
      deploy = File.read(DEPLOY)
      install = deploy.index(%(install_build_log_dir "$LOG_DIR"))
      assert install, "bin/chanbooru-deploy must install its log directory"
      assert_operator install, :<, deploy.index(%(: > "$LOG")), "the install must come before the log is truncated"
      assert_operator install, :<, deploy.index(%(tee "$LOG")), "the install must come before the build writes the log"
    end
  end

  context "build-watch" do
    # A copy of the two files in a checkout-shaped scratch root, so the
    # default location resolves inside this test's directory. Run through
    # bash because the dev stack mounts tmp/ noexec.
    setup do
      FileUtils.mkdir_p(File.join(@base, "bin"))
      FileUtils.mkdir_p(File.join(@base, "script"))
      FileUtils.cp(WATCH, File.join(@base, "bin/build-watch"))
      FileUtils.cp(LIB, File.join(@base, "script/chanbooru-build-log.sh"))
      @watch = File.join(@base, "bin/build-watch")
      @dir = File.join(@base, "tmp", "chanbooru-deploy")
    end

    should "refuse a missing log directory, naming it and the step that makes it, and not make it" do
      _out, err, st = Open3.capture3("bash", @watch, "--summary")
      assert_equal 1, st.exitstatus
      assert_match(/^FAIL: no build log directory at #{Regexp.escape(@dir)}/, err)
      assert_match(%r{^fix:\s+run bin/chanbooru-deploy}, err)
      refute File.exist?(@dir)
    end

    should "refuse a log directory open to group or other" do
      FileUtils.mkdir_p(@dir)
      File.chmod(0o755, @dir)
      _out, err, st = Open3.capture3("bash", @watch, "--summary")
      assert_equal 1, st.exitstatus
      assert_match(/^FAIL: .*is mode 755/, err)
    end

    should "summarise the log the deploy installed" do
      status, _out, err = lib(:install_build_log_dir, @dir, @uid)
      assert_equal 0, status, err
      File.write(File.join(@dir, "build.log"), "#1 [internal] load build definition\n#1 DONE 6.0s\n")
      out, err, st = Open3.capture3("bash", @watch, "--summary")
      assert_equal 0, st.exitstatus, err
      assert_includes out, "=== build: #{@dir}/build.log"
    end
  end
end
