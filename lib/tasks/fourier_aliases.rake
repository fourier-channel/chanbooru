# Tag aliases this deployment insists on, declared rather than hand-applied.
#
# WHY A TASK AND NOT A CONSOLE ONE-LINER. An alias created by hand in a console
# exists only in that database. It survives no rebuild, no restore, no second
# environment, and nothing anywhere records that it was ever wanted -- which is
# the standing ruling that a database change has to live in a repo to persist
# through the normal cycle. This file is that record, and re-running it is how
# the alias is restored.
#
# IDEMPOTENT BY CONSTRUCTION. TagRelationship.approve! is find_or_create_by! on
# (antecedent, consequent, active) and then re-runs process!, so running this
# twice re-applies the tag move rather than erroring or duplicating. That also
# makes it safe to run after an import that reintroduced the old spelling.
#
# WHAT IT DOES TO EXISTING POSTS. process! runs TagMover, which rewrites every
# post carrying the antecedent to carry the consequent instead. It is not a
# display-time rewrite -- the posts are edited. Reversible by rejecting the
# alias and moving back, but it is a real write to real posts, which is why the
# list is short and explicit rather than computed.

namespace :fourier do
  desc "Apply the tag aliases this deployment requires (idempotent)"
  task aliases: :environment do
    # antecedent => consequent. The left spelling disappears; the right wins.
    aliases = {
      "anus" => "butthole",
    }

    approver = User.system

    aliases.each do |antecedent, consequent|
      existing = TagAlias.active.find_by(antecedent_name: antecedent)
      if existing && existing.consequent_name != consequent
        # Do not silently retarget someone else's alias.
        warn "SKIP #{antecedent}: already aliased to #{existing.consequent_name}, not #{consequent}"
        next
      end

      before = Tag.find_by(name: antecedent)&.post_count || 0
      TagAlias.approve!(antecedent_name: antecedent, consequent_name: consequent, approver: approver)
      after = Tag.find_by(name: consequent)&.post_count || 0
      puts "ok  #{antecedent} -> #{consequent}  (moved from a tag with #{before} post(s); #{consequent} now #{after})"
    end
  end

  desc "Report the state of the aliases this deployment requires, changing nothing"
  task aliases_status: :environment do
    { "anus" => "butthole" }.each do |antecedent, consequent|
      ta = TagAlias.active.find_by(antecedent_name: antecedent)
      state =
        if ta.nil? then "ABSENT"
        elsif ta.consequent_name == consequent then "active"
        else "POINTS ELSEWHERE -> #{ta.consequent_name}"
        end
      puts format("%-12s -> %-12s %s (antecedent posts: %d, consequent posts: %d)",
                  antecedent, consequent, state,
                  Tag.find_by(name: antecedent)&.post_count || 0,
                  Tag.find_by(name: consequent)&.post_count || 0)
    end
  end
end
