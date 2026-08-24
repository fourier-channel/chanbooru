# frozen_string_literal: true

# Reads config/permission_manifest.yml and answers what a tier may do.
#
# Three states, and the middle one is the point:
#
#   :allow    the manifest permits -- the policy still decides
#   :deny     the manifest refuses, and that is final
#   :abstain  the manifest has no view; every other gate decides alone
#
# :allow and :abstain have the same effect at runtime, and that is deliberate
# rather than an oversight. This layer subtracts and never adds, so the strongest
# thing an :allow can do is decline to block. What separates them is meaning:
# :allow is a decision that was made, :abstain is one that has not been. That
# distinction is what makes coverage measurable -- see #undesigned.
#
# It also makes a claimed level worthless. Since nothing here can grant, a level
# that somehow arrived from the wrong place still has to satisfy the policies,
# which ask the session rather than the request.
class PermissionManifest
  PATH = Rails.root.join("config/permission_manifest.yml")

  # The band this manifest speaks for. Outside it the manifest abstains, which
  # is what stops a mostly-empty file from switching off the site: every
  # existing level is above this band and is governed exactly as it was.
  TIERS = (1..9)

  class Error < StandardError; end

  attr_reader :data

  def self.instance
    @instance ||= new(YAML.safe_load_file(PATH))
  end

  def self.reload!
    @instance = nil
    instance
  end

  def initialize(data)
    @data = data || {}
    raise Error, "manifest has no version" if @data["version"].blank?
  end

  def tiers = data.fetch("tiers", {})
  def realms = data.fetch("realms", {})
  def actions = data.fetch("actions", {})

  def tier_name(tier) = tiers.dig(tier, "name")

  # @param level [Integer] the user's level, read from their account
  # @param action [String] "surface.action"
  # @return [Symbol] :allow, :deny or :abstain
  def state(level:, action:, realm: "booru")
    return :abstain unless TIERS.cover?(level)

    entry = actions[action]
    return :deny if entry.nil?          # absent means off, always

    minimum = entry[realm]
    return :abstain if minimum.nil?     # explicitly undecided

    (level >= minimum) ? :allow : :deny
  end

  # The flat per-tier keys, derived rather than stored so the two forms cannot
  # drift apart. booru_t5_artist_update => true
  def flat_keys(realm: "booru")
    actions.each_with_object({}) do |(action, entry), out|
      minimum = entry[realm]
      next if minimum.nil?

      TIERS.each { |t| out["#{realm}_t#{t}_#{action.tr(".", "_")}"] = t >= minimum }
    end
  end

  # Action keys named here that no policy actually answers for. A rule about an
  # action that does not exist is not a rule, it is a typo with a comment above
  # it -- and it fails silently forever, since nothing ever asks it anything.
  def unknown_actions(inventory = self.class.inventory)
    actions.keys - inventory
  end

  # Real actions with no entry. These are OFF for every tier by default; the
  # list is how far the manifest has got, not a list of problems.
  def undesigned(inventory = self.class.inventory)
    inventory - actions.keys
  end

  # Every "surface.action" the application actually enforces, from the policies
  # themselves rather than from a list kept alongside them.
  def self.inventory
    PermissionMatrix.policies.flat_map do |policy|
      surface = policy.name.sub(/Policy\z/, "").underscore
      PermissionMatrix.actions_for(policy).map { |a| "#{surface}.#{a.to_s.delete_suffix("?")}" }
    end.uniq.sort
  end
end
