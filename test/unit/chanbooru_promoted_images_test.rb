require "test_helper"
require "open3"

# The images chanbooru derives from upstream ones (docker/<name>) are built on
# the workstation and loaded on the serving box by bin/chanbooru-image, never
# built or pulled there (vulnerability scan of 2026-10-24: upstream's archives
# and elasticmq images carried fixable criticals, and building on the box would
# give it new egress). The tag is the git tree hash of the directory.
#
# Proven here:
#   - both compose files name each such image at the tag its directory makes,
#     with pull_policy: never and nothing to build;
#   - the check refuses an image the box does not have, naming it and the
#     command that sends it, and passes one it has;
#   - the deploy runs the check before it builds or restarts anything.
class ChanbooruPromotedImagesTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("bin/chanbooru-image").to_s
  DEPLOY = Rails.root.join("bin/chanbooru-deploy").to_s
  COMPOSE_FILES = %w[docker-compose.yaml docker-compose.dev.yaml].map { |f| Rails.root.join(f).to_s }

  def git(*args)
    out, _err, st = Open3.capture3("git", "-C", Rails.root.to_s, *args)
    assert st.success?, "git #{args.join(" ")} failed"
    out
  end

  def promoted
    git("ls-tree", "-d", "--name-only", "HEAD", "docker/").split.map { |dir| dir.delete_prefix("docker/") }
  end

  # [exit status, stdout, stderr] of `bin/chanbooru-image check` with a docker
  # that answers image inspect as told, and asserted to have been asked: a
  # docker that never ran refuses too. Under /tmp, not tmp/, which the dev
  # stack mounts noexec.
  def check(present)
    Dir.mktmpdir("docker-") do |bin|
      File.write(File.join(bin, "docker"), "#!/bin/sh\necho \"$*\" >> #{bin}/calls\n[ \"$1 $2\" = \"image inspect\" ] && exit #{present ? 0 : 1}\nexit 2\n")
      File.chmod(0o755, File.join(bin, "docker"))
      out, err, st = Open3.capture3({ "PATH" => "#{bin}:#{ENV.fetch("PATH")}" }, SCRIPT, "check", chdir: Rails.root.to_s)
      assert_match(/^image inspect chanbooru-archives:\h{12}$/, File.read(File.join(bin, "calls")), "the check must ask docker for the image")
      [st.exitstatus, out, err]
    end
  end

  context "the compose files" do
    should "name each promoted image at its directory's tree hash, never pulled or built" do
      assert_includes promoted, "archives"
      COMPOSE_FILES.each do |file|
        services = YAML.load_file(file, aliases: true).fetch("services")
        promoted.each do |name|
          assert git("ls-tree", "--name-only", "HEAD", "docker/#{name}/").split.include?("docker/#{name}/smoke.sh"), "docker/#{name} needs a smoke.sh for bin/chanbooru-image"
          tag = git("rev-parse", "HEAD:docker/#{name}").strip[0, 12]
          using = services.select { |_, svc| svc["image"].to_s.start_with?("chanbooru-#{name}:") }
          assert_equal 1, using.size, "#{File.basename(file)}: one service runs chanbooru-#{name}"
          service, svc = using.first
          assert_equal "chanbooru-#{name}:#{tag}", svc["image"], "#{File.basename(file)} #{service}: docker/#{name} at HEAD makes chanbooru-#{name}:#{tag}"
          assert_equal "never", svc["pull_policy"], "#{File.basename(file)} #{service}: a promoted image is never pulled"
          assert_nil svc["build"], "#{File.basename(file)} #{service}: a promoted image is built by bin/chanbooru-image, not compose"
        end
      end
    end
  end

  context "the check" do
    should "refuse an image this box does not have, and say how to send it" do
      status, _out, err = check(false)
      assert_equal 1, status
      assert_match(/^FAIL: chanbooru-archives:\h{12} is not on this box/, err)
      assert_match(%r{^fix: .*bin/chanbooru-image archives promote}, err)
    end

    should "pass when every image is here" do
      status, out, err = check(true)
      assert_equal 0, status, err
      promoted.each { |name| assert_match(/chanbooru-#{name}:\h{12} present/, out) }
    end
  end

  context "the deploy" do
    should "check the promoted images before it builds or restarts anything" do
      deploy = File.read(DEPLOY)
      check = deploy.index(%(bin/chanbooru-image check || die))
      assert check, "bin/chanbooru-deploy must run bin/chanbooru-image check and die on refusal"
      assert_operator check, :<, deploy.index("bin/build-docker-image danbooru"), "the check must come before the build"
      assert_operator check, :<, deploy.index("docker compose --progress quiet up -d"), "the check must come before compose up"
    end
  end
end
