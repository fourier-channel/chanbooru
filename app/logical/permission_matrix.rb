# frozen_string_literal: true

# What can a user at each level actually do?
#
# The answer is currently spread across 80-odd Pundit policies as Ruby method
# bodies, which means nobody can see it. Not the operator deciding what a tier
# should be worth, not the reviewer checking a change did not widen something by
# accident, and not the next person wondering why a level exists at all. This
# enumerates every policy against a synthetic user at every level and returns
# the grid.
#
# It is deliberately a real class rather than a script. The grid is the input to
# the permission manifest, the baseline a change gets diffed against, and the
# subject of the monotonicity test next to it -- three jobs that all want the
# same code, and the version of this that got thrown away after one use was the
# reason the same questions kept being re-answered from scratch.
class PermissionMatrix
  # The actions ApplicationPolicy defines for every resource. Policies add their
  # own beyond these (approve?, unban?, promote?); those are enumerated too, via
  # ACTION_SUFFIX, but these are the ones every surface answers for.
  CORE_ACTIONS = %i[index? show? create? update? destroy?].freeze

  # A policy method is an "action" if it ends in ? and is not one of Pundit's or
  # ApplicationPolicy's plumbing. Without this the grid fills up with
  # permitted_attributes and policy(object).
  NOT_ACTIONS = %i[unbanned?].freeze

  Cell = Struct.new(:policy, :action, :allowed, :error, keyword_init: true) do
    def state
      if error
        :error
      else
        (allowed ? :allow : :deny)
      end
    end
  end

  attr_reader :levels

  def initialize(levels: self.class.default_levels)
    @levels = levels
  end

  # Every level the application defines, plus anything else asked for. Ordered,
  # because the whole point of a level is that it is comparable.
  def self.default_levels
    User::Levels.constants.to_h { |c| [c.to_s.downcase, User::Levels.const_get(c)] }
                          .sort_by { |_name, value| value }.to_h
  end

  def self.policies
    @policies ||= Dir[Rails.root.join("app/policies/*_policy.rb")]
                  .map { |f| File.basename(f, ".rb").camelize.safe_constantize }
                  .compact
                  .select { |k| k.is_a?(Class) && k < ApplicationPolicy }
                  .sort_by(&:name)
  end

  # The actions a given policy answers for: the core five, plus any question
  # method the policy itself declares.
  def self.actions_for(policy)
    own = policy.instance_methods(false).grep(/\?\z/)
    (CORE_ACTIONS + own).uniq - NOT_ACTIONS
  end

  # @return [Hash] level name => Array<Cell>
  def grid
    @grid ||= levels.transform_values { |value| cells_for(User.new(level: value, name: "matrix")) }
  end

  def allowed(level_name)
    grid.fetch(level_name).select { |c| c.state == :allow }
  end

  # The set of "Policy#action" strings a level may perform. Sets, because the
  # question worth asking of two levels is whether one contains the other.
  def capability_set(level_name)
    allowed(level_name).map { |c| "#{c.policy}##{c.action}" }.to_set
  end

  private

  def cells_for(user)
    self.class.policies.flat_map do |policy|
      record = sample_record(policy)
      self.class.actions_for(policy).filter_map do |action|
        instance = policy.new(user, record)
        next unless instance.respond_to?(action)

        begin
          Cell.new(policy: policy.name.sub(/Policy\z/, ""), action: action, allowed: instance.public_send(action) ? true : false)
        rescue StandardError => e
          # Recorded, NOT swallowed into a deny. A probe that turns its own
          # errors into "not allowed" reports a perfectly locked system no
          # matter what the code underneath it says, which is the most
          # comfortable possible way to be wrong about permissions.
          Cell.new(policy: policy.name.sub(/Policy\z/, ""), action: action, allowed: false, error: e.class.name)
        end
      end
    end
  end

  # An unsaved instance of the policy's model, where there is one. Some policies
  # need a persisted record to answer and will raise; that is what `error` is
  # for, and an errored cell is reported rather than counted either way.
  def sample_record(policy)
    model = policy.name.sub(/Policy\z/, "").safe_constantize
    return nil unless model.respond_to?(:new) && model.respond_to?(:column_names)

    model.new
  rescue StandardError
    nil
  end
end
