# frozen_string_literal: true

require "test_helper"

class PermissionManifestTest < ActiveSupport::TestCase
  setup { @manifest = PermissionManifest.instance }

  context "The permission manifest" do
    should "only name actions the application actually enforces" do
      # A rule about an action no policy answers for is not a rule, it is a typo
      # with a comment above it -- and it fails silently forever, because
      # nothing ever asks it anything. This is the check that catches a policy
      # being renamed out from under an entry here.
      assert_empty(@manifest.unknown_actions, "manifest names actions that no policy has")
    end

    should "abstain entirely outside the tier band" do
      # The property that stops a near-empty manifest from switching off the
      # site. Every existing level sits above the band and must be governed
      # exactly as it was before this file existed.
      outside = [User::Levels::ANONYMOUS, User::Levels::RESTRICTED, User::Levels::MEMBER,
                 User::Levels::MODERATOR, User::Levels::ADMIN, User::Levels::OWNER, 99, -1]

      outside.each do |level|
        assert_equal(:abstain, @manifest.state(level: level, action: "post.index"),
                     "manifest must not answer for level #{level}")
        assert_equal(:abstain, @manifest.state(level: level, action: "post.destroy"))
      end
    end

    should "deny any action it does not mention" do
      PermissionManifest::TIERS.each do |tier|
        assert_equal(:deny, @manifest.state(level: tier, action: "post.expunge"))
        assert_equal(:deny, @manifest.state(level: tier, action: "totally.invented"))
      end
    end

    should "be monotonic across tiers for every action" do
      # Guaranteed by storing a threshold rather than a flag per tier, so this
      # asserts the storage shape has not been quietly replaced by a grid that
      # permits t7-yes / t8-no.
      @manifest.actions.each_key do |action|
        states = PermissionManifest::TIERS.map { |t| @manifest.state(level: t, action: action) }
        allowed_from = states.index(:allow)
        next if allowed_from.nil?

        assert(states[allowed_from..].all? { |s| s == :allow },
               "#{action} is allowed at one tier and not at a higher one")
      end
    end

    should "derive flat keys that agree with the resolver" do
      # The two representations exist because the operator thinks in
      # booru_t5_artist_update and Matrix thinks in thresholds. They may never
      # disagree, which is why only one of them is stored.
      @manifest.flat_keys.each do |key, value|
        tier = key[/\Abooru_t(\d)_/, 1].to_i
        action = key.sub(/\Abooru_t\d_/, "").tr("_", ".")
        # tr is lossy where an action itself contains an underscore, so only
        # assert on keys that round-trip cleanly.
        next unless @manifest.actions.key?(action)

        assert_equal(value, @manifest.state(level: tier, action: action) == :allow, key)
      end
    end

    should "know how much of the surface is still undesigned" do
      assert_operator(@manifest.undesigned.size, :>, 0, "nothing left to design is implausible")
      assert_equal(PermissionManifest.inventory.size,
                   @manifest.actions.size + @manifest.undesigned.size,
                   "every real action is either designed or undesigned, never both or neither")
    end
  end
end
