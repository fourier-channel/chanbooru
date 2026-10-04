require "test_helper"
require "open3"

# A release is the code the production containers run: one commit's app tree,
# compiled assets and bootsnap cache, installed by bin/chanbooru-release and
# mounted read-only at /danbooru in place of the copy baked into the image
# (fourier-basis docs/design/CHANBOORU_RELEASES.md, 2026-10-04). Its locations
# are trusted only because that script made them (INSTALLED_LOCATIONS_LAW).
#
# Proven here, against directories this test makes (install itself needs
# docker, which the test container does not have; the rehearsal on vesper ran
# it end to end):
#   - compose mounts the release, read-only and never created, at the path
#     the script installs, in every service that runs the app or serves it;
#   - activate points `current` at an installed release only, refuses to
#     replace anything but its own link, and refuses a group-writable root;
#   - previous and prune keep what a rollback needs;
#   - the deploy installs and activates before it restarts anything, and
#     verifies the release's revision, not the image's.
class ChanbooruReleasesTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("bin/chanbooru-release").to_s
  COMPOSE = Rails.root.join("docker-compose.yaml").to_s
  DEPLOY = Rails.root.join("bin/chanbooru-deploy").to_s

  def setup
    @root = Dir.mktmpdir("releases-", Rails.root.join("tmp").to_s)
    File.chmod(0o755, @root)
    @head = `git -C #{Rails.root} rev-parse HEAD`.strip
    @parent = `git -C #{Rails.root} rev-parse HEAD~1`.strip
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  # [exit status, stdout, stderr] of the script's CLI with its root moved here.
  def release(*args)
    out, err, st = Open3.capture3({ "CHANBOORU_RELEASES_ROOT" => @root }, SCRIPT, *args.map(&:to_s), chdir: Rails.root.to_s)
    [st.exitstatus, out, err]
  end

  # A release as install leaves one, without docker: a directory named for
  # the commit holding its REVISION.
  def fake_release(sha)
    dir = File.join(@root, "releases", sha[0, 12])
    FileUtils.mkdir_p(dir, mode: 0o755)
    File.chmod(0o755, File.join(@root, "releases"))
    File.write(File.join(dir, "REVISION"), "#{sha}\n")
    dir
  end

  context "the production compose file" do
    should "mount the release read-only at /danbooru, never created, in every app service" do
      compose = YAML.load_file(COMPOSE, aliases: true)
      services = %w[danbooru cron jobs nginx]
      services.each do |name|
        mounts = compose.dig("services", name, "volumes").select { |v| v.is_a?(Hash) && v["target"] == "/danbooru" }
        assert_equal 1, mounts.size, "#{name} must mount the release at /danbooru exactly once"
        m = mounts.first
        assert_equal "bind", m["type"], name
        assert_equal "${CHANBOORU_RELEASES_ROOT:-/srv/danbooru}/current", m["source"], "#{name} must mount the path bin/chanbooru-release installs"
        assert_equal true, m["read_only"], "#{name} must mount the release read-only"
        assert_equal false, m.dig("bind", "create_host_path"), "#{name} must refuse a missing release, never create one"
      end
    end

    should "name the same releases root as the script" do
      script_default = File.read(SCRIPT)[/RELEASES_ROOT="\$\{CHANBOORU_RELEASES_ROOT:-([^}]+)\}"/, 1]
      assert_equal "/srv/danbooru", script_default
      assert_includes File.read(COMPOSE), "${CHANBOORU_RELEASES_ROOT:-#{script_default}}/current"
    end
  end

  context "activate" do
    should "point current at an installed release, and record it" do
      dir = fake_release(@head)
      st, out, err = release(:activate, @head)
      assert_equal 0, st, err
      assert_equal dir, File.readlink(File.join(@root, "current"))
      assert_match(/current -> #{@head[0, 12]}/, out)
      assert_equal [@head[0, 12]], File.readlines(File.join(@root, "history"), chomp: true)
    end

    should "refuse a commit that is not installed" do
      FileUtils.mkdir_p(File.join(@root, "releases"), mode: 0o755)
      st, _out, err = release(:activate, @head)
      assert_equal 1, st
      assert_match(/FAIL: .*not an installed release/, err)
      assert_match(/fix: .*install/, err)
      refute File.exist?(File.join(@root, "current"))
    end

    should "refuse to replace a current that is not its own link" do
      fake_release(@head)
      File.write(File.join(@root, "current"), "someone else's")
      st, _out, err = release(:activate, @head)
      assert_equal 1, st
      assert_match(/FAIL: .*not a link/, err)
      assert_equal "someone else's", File.read(File.join(@root, "current"))
    end

    should "refuse a current pointing outside its releases" do
      fake_release(@head)
      File.symlink("/etc", File.join(@root, "current"))
      st, _out, err = release(:activate, @head)
      assert_equal 1, st
      assert_match(/FAIL: .*outside/, err)
    end

    should "refuse a releases root writable by group or other" do
      fake_release(@head)
      File.chmod(0o775, @root)
      st, _out, err = release(:activate, @head)
      assert_equal 1, st
      assert_match(/FAIL: .*writable by group or other/, err)
      assert_match(/fix:\s+chmod go-w/, err)
    end
  end

  context "previous and prune" do
    should "name the release before the current one, and keep it when pruning" do
      fake_release(@parent)
      fake_release(@head)
      assert_equal 0, release(:activate, @parent).first
      assert_equal 0, release(:activate, @head).first
      st, out, err = release(:previous)
      assert_equal 0, st, err
      assert_equal @parent[0, 12], out.strip

      st, _out, err = release(:prune)
      assert_equal 0, st, err
      assert File.exist?(File.join(@root, "releases", @head[0, 12], "REVISION"))
      assert File.exist?(File.join(@root, "releases", @parent[0, 12], "REVISION"))
    end

    should "say plainly when there is nothing to roll back to" do
      fake_release(@head)
      assert_equal 0, release(:activate, @head).first
      st, _out, err = release(:previous)
      assert_equal 1, st
      assert_match(/FAIL: no earlier installed release/, err)
    end
  end

  context "the deploy" do
    should "install and activate the release before it restarts anything" do
      deploy = File.read(DEPLOY)
      install = deploy.index("bin/chanbooru-release install")
      activate = deploy.index("bin/chanbooru-release activate \"$TARGET\"")
      restart = deploy.index("up -d --force-recreate danbooru cron jobs nginx")
      assert install && activate && restart, "the deploy must install, activate and recreate the app services"
      assert install < activate, "install before activate"
      assert activate < restart, "activate before the restart"
    end

    should "verify the release's revision, not the image's" do
      deploy = File.read(DEPLOY)
      assert_includes deploy, "cat /danbooru/REVISION"
      refute_includes deploy, "printenv DOCKER_IMAGE_REVISION"
    end
  end
end
