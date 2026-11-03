require "test_helper"

# On the serving box danbooru.service runs a detached `docker compose up -d`
# and exits (fourier-basis ops/hetzner/danbooru, 2026-11-03), so nothing but a
# container's own restart policy brings it back after a crash or a dockerd
# restart. Before that, nginx, redis, postgres and iqdb had none, and the
# attached unit's Restart=always only ever restarted compose's client.
class ChanbooruRestartPolicyTest < ActiveSupport::TestCase
  should "restart every production service unless it was stopped" do
    services = YAML.load_file(Rails.root.join("docker-compose.yaml"), aliases: true).fetch("services")
    without = services.reject { |_, svc| svc["restart"] == "unless-stopped" }.keys
    assert_empty without, "docker-compose.yaml: these services have no restart: unless-stopped"
  end
end
