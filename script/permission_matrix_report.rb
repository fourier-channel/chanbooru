# frozen_string_literal: true

# Renders PermissionMatrix for a terminal. See bin/permission-matrix.
ActiveRecord::Base.logger = nil

args = ARGV.dup
matrix = PermissionMatrix.new
names = matrix.levels.keys

def cell_mark(state)
  { allow: "#", deny: ".", error: "?" }.fetch(state)
end

if args.first == "--level"
  level = args[1] or abort("--level needs a level name: #{names.join(", ")}")
  abort("unknown level #{level}. known: #{names.join(", ")}") unless matrix.levels.key?(level)
  allowed = matrix.allowed(level).group_by(&:policy)
  puts "#{level} (level #{matrix.levels[level]}) may perform #{matrix.capability_set(level).size} actions:"
  allowed.sort.each { |policy, cells| puts format("  %-28s %s", policy, cells.map(&:action).sort.join(" ")) }
  exit 0
end

if args.first == "--diff"
  a, b = args[1], args[2]
  abort("--diff needs two level names") if a.nil? || b.nil?
  [a, b].each { |n| abort("unknown level #{n}") unless matrix.levels.key?(n) }
  gained = (matrix.capability_set(b) - matrix.capability_set(a)).to_a.sort
  lost   = (matrix.capability_set(a) - matrix.capability_set(b)).to_a.sort
  puts "#{b} gains #{gained.size} over #{a}:"
  gained.each { |c| puts "  + #{c}" }
  puts
  puts "#{b} loses #{lost.size} that #{a} has:"
  lost.each { |c| puts "  - #{c}" }
  exit 0
end

per_action = args.include?("--actions")
header = names.map { |n| n[0, 4] }

puts "# = allowed   . = denied   ? = policy raised (reported, never counted as a denial)"
puts
puts format("%-34s %s", "", header.map { |h| h.ljust(5) }.join)

rows = Hash.new { |h, k| h[k] = {} }
names.each do |name|
  matrix.grid.fetch(name).each do |cell|
    key = per_action ? "#{cell.policy}##{cell.action}" : cell.policy
    if per_action
      rows[key][name] = cell.state
    else
      # Surface-level summary: how many of this surface's actions are open.
      rows[key][name] = (rows[key][name] || 0) + ((cell.state == :allow) ? 1 : 0)
    end
  end
end

rows.keys.sort.each do |key|
  marks = names.map do |name|
    v = rows[key][name]
    per_action ? cell_mark(v).ljust(5) : v.to_s.ljust(5)
  end
  puts format("%-34s %s", (key.length > 33) ? "#{key[0, 30]}..." : key, marks.join)
end

puts
puts "totals:"
names.each { |n| puts format("  %-12s %4d allowed", n, matrix.capability_set(n).size) }
