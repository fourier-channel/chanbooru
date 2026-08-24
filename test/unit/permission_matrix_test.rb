# frozen_string_literal: true

require "test_helper"

# The level scale has to actually be a scale.
#
# Levels are compared with >= in three hundred places, which only means anything
# if a higher level can do everything a lower one can. Nothing enforced that.
# The check matters most for the thing it makes structurally impossible: an
# ability intended for one tier cannot leak downward to a lower tier through a
# rule that was written assuming the ordering held.
class PermissionMatrixTest < ActiveSupport::TestCase
  # Actions only a logged-OUT visitor performs. A member cannot "log in" or
  # "reset a forgotten password" because they are already past that door, so
  # anonymous holding these while restricted does not is correct, and is the
  # single legitimate exception to the ordering. Listed by name rather than
  # waved away, so that a NEW exception has to be argued for here.
  LOGGED_OUT_ONLY = %w[
    PasswordReset#create? PasswordReset#destroy? PasswordReset#show? PasswordReset#update?
    SessionLoader#create? SessionLoader#new? SessionLoader#verify_totp?
    User#new? User#create?
  ].to_set

  # User#create? is signup, and it only shows up as an asymmetry where signup is
  # OPEN -- which on this fork is the test environment and nowhere else. That it
  # appears here and not in development is the config difference working as
  # intended, not a discrepancy to paper over.

  context "The permission matrix" do
    setup do
      @matrix = PermissionMatrix.new
      @names = @matrix.levels.keys
    end

    should "find every policy in the application" do
      # A matrix that silently enumerated nothing would pass every other test
      # here, which is the failure mode worth spending an assertion on.
      assert_operator(PermissionMatrix.policies.size, :>=, 50)
      assert_includes(PermissionMatrix.policies, PostPolicy)
    end

    should "be monotonic: no level may do something the level above it cannot" do
      offenders = @names.each_cons(2).filter_map do |lower, higher|
        lost = @matrix.capability_set(lower) - @matrix.capability_set(higher) - LOGGED_OUT_ONLY
        ["#{lower} -> #{higher}: #{lost.to_a.sort.join(", ")}"] if lost.any?
      end

      assert_empty(offenders.flatten, <<~MSG)
        A lower level can do something a higher level cannot. Either the
        capability is genuinely logged-out-only (add it to LOGGED_OUT_ONLY with
        a reason) or the ordering is broken and every `level >=` comparison
        guarding it is now wrong.
      MSG
    end

    should "grant strictly more at member than below it" do
      # The cliff this fork's tiers are meant to smooth out. Asserted so that
      # flattening it is a deliberate act rather than a side effect.
      below = @matrix.capability_set("restricted")
      member = @matrix.capability_set("member")

      assert_operator(member.size, :>, below.size)
      assert_empty(below - member - LOGGED_OUT_ONLY)
    end

    should "report probe failures rather than counting them as denials" do
      # The trap this class was written around: a probe that rescues into
      # "not allowed" reports a perfectly locked system regardless of the code
      # underneath it. Errored cells must stay visible as errors.
      cells = @matrix.grid.fetch("member")
      errored = cells.select { |c| c.state == :error }

      assert(errored.all? { |c| c.error.present? }, "an errored cell must carry its exception class")
      assert_not_equal(cells.size, cells.count { |c| c.state == :deny }, "every cell denied -- the probe is not exercising the policies")
    end
  end
end
