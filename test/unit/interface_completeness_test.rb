# frozen_string_literal: true

require "test_helper"

# THE CHECKLIST: everything an interface is missing, each with its fix.
# Adding interface #2 is: make app/interfaces/<name>, add its line to
# Interface::TABLE (app/logical/interface.rb), and do what this test says.
#
# What a file can break of the contract an interface gets:
#   1. a folder holds views/, components/, javascript/ and stylesheets/ only;
#      every view overrides an upstream page (or a variant of one) by path
#      and is listed in its line's `draws`, every `draws` entry has its file,
#      and every folder has a line;
#   5. no cache block in an interface's drawing, nor in a core or upstream
#      template whose render tree reaches a template an interface draws:
#      fragment keys do not vary by interface, so one interface's fragment
#      would be served to another's viewers;
#   6. every stylesheet rule sits under body[data-preset="<name>"], since one
#      bundle carries every interface's CSS to every viewer;
#   7. every layout an interface draws reaches #blacklist-box (the
#      BlocklistComponent; without it blacklisted posts are drawn) and the
#      purge control, and a posts/show it draws reaches the opened=1 request
#      that writes the admin-view log.
# Not checked: that an interface's JS does nothing on another interface's
# pages (item 6). No shape of a file shows that.
#
# Each check is proved by a fixture under test/files/interfaces/checklist
# that breaks it, so a check that stopped finding anything goes red here.
class InterfaceCompletenessTest < ActiveSupport::TestCase
  ROOT = Rails.root.join("app/interfaces")
  UPSTREAM_VIEWS = Rails.root.join("app/views")
  CHECKLIST = Rails.root.join("test/files/interfaces/checklist")
  PARTS = %w[views components javascript stylesheets].freeze
  CACHE = /<%-?\s*cache[\s(]|\bcache\s*\(.*\)\s*do\b/
  PARTIAL = %r{\brender\(?\s*(?:partial:\s*)?["']([\w/]+)["']}
  COMPONENT = /\brender\(?\s*([A-Z]\w*Component)\.(?:new|with_collection)\b/
  # Any render the follower cannot name: a variable, a collection, a helper
  # that renders (render_tag_change_notice), a yield.
  RENDER = /\brender(?:_\w+)?\b(?!\?)|<%=\s*yield\b/

  # The upstream page or partial behind a key, with any format or variant.
  def self.upstream?(key)
    UPSTREAM_VIEWS.glob("#{key.sub(/\+\w+\z/, "")}.*").any?
  end

  # Every file a template's drawing is made of, by text: the template, the
  # partials it renders by name (the interface's copy first), the components
  # it renders by class, and theirs in turn.
  # @return [Array(Hash{Pathname => String}, Array<String>)] the files with
  #   their text, and every render it could not follow, "file: text".
  def self.tree(file, views: nil, found: {}, unfollowed: [])
    return [found, unfollowed] if found.key?(file)

    text = found[file] = file.read
    # A name with no folder is the rendering view's own folder's.
    dir = file.to_s[%r{/views/(.+)/[^/]+\z}, 1]
    partials = text.scan(PARTIAL).flatten.map { |name| (name.include?("/") || dir.nil?) ? name : "#{dir}/#{name}" }
    partial_files = partials.filter_map do |name|
      folder, base = File.split(name)
      [views, UPSTREAM_VIEWS].compact.lazy.filter_map { |root| root.glob("#{folder}/_#{base}.*").min }.first
    end
    component_files = text.scan(COMPONENT).flatten.uniq.flat_map do |klass|
      stem = klass.underscore
      [Rails.root.join("app/components"), *ROOT.glob("*/components")].flat_map do |root|
        [root.join("#{stem}.rb"), *root.glob("#{stem}/#{stem}.html*"), *root.glob("#{stem}.html*")].select(&:exist?)
      end
    end
    text.each_line.with_index(1)
        .select { |line, _| line.match?(RENDER) && !line.match?(PARTIAL) && !line.match?(COMPONENT) && !line.match?(/^\s*(#|<%#|def )/) }
        .each { |line, number| unfollowed << "#{file.relative_path_from(Rails.root)}:#{number}: #{line.strip}" }
    (partial_files + component_files).each { |child| tree(child, views: views, found: found, unfollowed: unfollowed) }
    [found, unfollowed]
  end

  # The rules in a stylesheet that are not under body[data-preset="<name>"],
  # as "file:line: selector". A rule inside a scoped rule, a @mixin, a
  # @function, @keyframes, @font-face or @property paints nothing on its
  # own; @media, @supports, @container, @layer and Sass control flow are
  # looked inside. A top-level @include can emit any rule, so it counts.
  def self.unscoped(file, name)
    scope = %{body[data-preset="#{name}"]}
    text = file.read.gsub(%r{/\*.*?\*/}m) { |c| "\n" * c.count("\n") }.gsub(%r{(^|\s)//[^\n]*}, '\1').gsub(/#\{[^}]*\}/, "INTERP")
    stack = [:top]
    start = 0
    text.each_char.with_index.each_with_object([]) do |(char, index), found|
      next unless "{};".include?(char)

      prelude = text[start...index].strip
      line = text[0...index].count("\n") + 1 - prelude.count("\n")
      start = index + 1
      if char == "}"
        stack.pop
      elsif stack.last != :top
        stack.push(:inside) if char == "{"
      elsif char == ";"
        found << "#{file.relative_path_from(Rails.root)}:#{line}: #{prelude}" if prelude.start_with?("@include")
      elsif prelude.match?(/\A@(media|supports|container|layer|if|else|each|for|while)\b/)
        stack.push(:top)
      elsif prelude.match?(/\A@(mixin|function|keyframes|font-face|property)\b/)
        stack.push(:inside)
      else
        selectors = prelude.split(",").map(&:strip)
        found << "#{file.relative_path_from(Rails.root)}:#{line}: #{prelude.squish}" unless selectors.all? { |s| s.start_with?(scope, "%") }
        stack.push(:inside)
      end
    end
  end

  # Every gap in one interface, each with its fix.
  def self.gaps(interface)
    folder = interface.folder
    views = folder.join("views")
    view_files = views.glob("**/*").select(&:file?).reject { |file| file.basename.to_s == ".keep" }
    drawn = view_files.index_by { |file| Interface.draws_key(file.relative_path_from(views).to_s) }
    line = "its line in Interface::TABLE (app/logical/interface.rb)"
    rel = ->(file) { file.relative_path_from(Rails.root).to_s }

    stray = folder.children.reject { |child| child.directory? && PARTS.include?(child.basename.to_s) }.map do |child|
      "#{rel[child]} is not drawing: an interface folder holds #{PARTS.join("/, ")}/ only; fix: move it into one of them, or out of app/interfaces"
    end
    pageless = drawn.reject { |k, _| upstream?(k) }.map do |k, file|
      "#{rel[file]} overrides no upstream page (no app/views/#{k.sub(/\+\w+\z/, "")}.*): an interface cannot add a page; fix: name it after the page it draws, or delete it"
    end
    unlisted = (drawn.keys - interface.draws).map { |k| "#{rel[drawn[k]]} is drawn but #{k.inspect} is not in `draws`; fix: add it to #{line}" }
    unfiled = (interface.draws - drawn.keys).map { |k| "`draws` lists #{k.inspect} and #{rel[views]} has no file for it; fix: add the file, or take it out of #{line}" }

    drawing = view_files + folder.glob("components/**/*").select(&:file?)
    cached = drawing.select { |file| file.read.match?(CACHE) }.map do |file|
      "#{rel[file]} has a cache block: fragment keys do not vary by interface; fix: remove the cache block"
    end
    stylesheets = folder.glob("**/*.scss").flat_map { |file| unscoped(file, interface.name) }.map do |rule|
      "#{rule} is not under body[data-preset=\"#{interface.name}\"]; fix: nest it in that rule"
    end

    duties = drawn.flat_map do |k, file|
      text = tree(file, views: views).first.values.join("\n")
      layout = k.start_with?("layouts/") && k.exclude?("/_")
      [
        layout && text.exclude?("BlocklistComponent") && "#{rel[file]} never reaches #blacklist-box, so blacklisted posts are drawn; fix: render BlocklistComponent in its header",
        layout && text.exclude?('data-act="purge"') && "#{rel[file]} never reaches the purge control; fix: render it in its header beside the blocklist",
        k == "posts/show" && text.exclude?("opened=1") && "#{rel[file]} never sends the opened=1 request that logs an admin's view of a hidden post; fix: send it when the payload's logs_admin_view is set",
      ].select(&:itself)
    end

    stray + pageless + unlisted + unfiled + cached + stylesheets + duties
  end

  # A cache block in core or upstream drawing whose render tree reaches a
  # template some interface draws (or a render it cannot follow).
  def self.core_cache_gaps(drawn_keys, files: [UPSTREAM_VIEWS, Rails.root.join("app/components")].flat_map { |root| root.glob("**/*.{erb,rb}") })
    files.select { |file| file.read.match?(CACHE) }.flat_map do |file|
      found, unfollowed = tree(file)
      reached = found.keys.filter_map { |f| Interface.draws_key(f.relative_path_from(UPSTREAM_VIEWS).to_s) if f.to_s.start_with?("#{UPSTREAM_VIEWS}/") } & drawn_keys
      where = file.relative_path_from(Rails.root)
      reached.map { |k| "#{where} caches a fragment that reaches #{k}, which an interface draws; fix: remove the cache block" } +
        unfollowed.map { |render| "#{where} caches a fragment with a render this check cannot follow (#{render}); fix: remove the cache block, or render by name" }
    end
  end

  def self.fixture(name, draws: [])
    Interface.new(number: 90, name: name, folder: CHECKLIST.join(name), draws: draws)
  end

  context "The interfaces in Interface::TABLE" do
    should "each have every part the contract asks for" do
      gaps = Interface::TABLE.reject(&:classic?).flat_map { |interface| self.class.gaps(interface) }
      assert_empty(gaps, "an interface is incomplete:\n#{gaps.join("\n")}")
    end

    should "each have a line, folder by folder" do
      names = Interface::TABLE.map(&:name)
      orphans = ROOT.children.select(&:directory?).map { |dir| dir.basename.to_s } - names
      assert_empty(orphans, "app/interfaces has a folder with no line in Interface::TABLE: #{orphans.join(", ")}; " \
                            "fix: add its line to Interface::TABLE (app/logical/interface.rb), or remove the folder")
      loose = ROOT.children.reject(&:directory?).map { |file| file.relative_path_from(Rails.root).to_s }
      assert_empty(loose, "app/interfaces holds folders only; fix: move each into its interface's folder")
    end

    should "leave no cache block in core drawing that reaches a template an interface draws" do
      gaps = self.class.core_cache_gaps(Interface::TABLE.flat_map(&:draws))
      assert_empty(gaps, gaps.join("\n"))
    end
  end

  # Each check, broken on purpose: if one stops finding its gap, it is red here.
  context "The checklist" do
    should "name a file that is not drawing, and a view that overrides no page" do
      gaps = self.class.gaps(self.class.fixture("stray", draws: ["posts/nonesuch"]))
      assert(gaps.any? { |gap| gap.include?("checklist/stray/notes.rb is not drawing") && gap.include?("fix:") }, gaps.join("\n"))
      assert(gaps.any? { |gap| gap.include?("views/posts/nonesuch.html.erb overrides no upstream page") }, gaps.join("\n"))
    end

    should "name a variant drawn and not listed, and a listed page with no file" do
      gaps = self.class.gaps(self.class.fixture("unlisted", draws: ["posts/index", "posts/show"]))
      assert(gaps.any? { |gap| gap.include?('"posts/index+window" is not in `draws`') }, gaps.join("\n"))
      assert(gaps.any? { |gap| gap.include?('`draws` lists "posts/show"') }, gaps.join("\n"))
      assert_not(gaps.any? { |gap| gap.include?('"posts/index" is not in') }, gaps.join("\n"))
    end

    should "name a cache block in an interface's drawing" do
      gaps = self.class.gaps(self.class.fixture("cached", draws: ["posts/show"]))
      assert(gaps.any? { |gap| gap.include?("views/posts/show.html.erb has a cache block") }, gaps.join("\n"))
    end

    should "name a cache block in core drawing that reaches a template an interface draws, or a render it cannot follow" do
      gaps = self.class.core_cache_gaps(["users/_upgrade_notice"], files: [CHECKLIST.join("core/views/tags/cached.html.erb")])
      assert(gaps.any? { |gap| gap.include?("reaches users/_upgrade_notice, which an interface draws") }, gaps.join("\n"))
      assert(gaps.any? { |gap| gap.include?("cannot follow") && gap.include?("render @things") }, gaps.join("\n"))
      assert_empty(self.class.core_cache_gaps(["users/_dmail_notice"], files: [CHECKLIST.join("core/views/tags/cached.html.erb")]).grep(/reaches/))
    end

    should "name a stylesheet rule outside body[data-preset]" do
      gaps = self.class.gaps(self.class.fixture("unscoped"))
      flagged = gaps.grep(/is not under body\[data-preset="unscoped"\]/)
      assert_equal(3, flagged.size, "the loose rule, the @include and the rule in @media, and nothing scoped:\n#{gaps.join("\n")}")
    end

    should "name a layout that never reaches #blacklist-box or purge, and a post page that never sends opened=1" do
      gaps = self.class.gaps(self.class.fixture("dutiless", draws: ["layouts/default", "posts/show"]))
      assert(gaps.any? { |gap| gap.include?("layouts/default.html.erb never reaches #blacklist-box") }, gaps.join("\n"))
      assert(gaps.any? { |gap| gap.include?("layouts/default.html.erb never reaches the purge control") }, gaps.join("\n"))
      assert(gaps.any? { |gap| gap.include?("posts/show.html.erb never sends the opened=1 request") }, gaps.join("\n"))
    end

    # The follower is what the duty checks stand on: from upstream's own
    # default layout it must reach both headers' BlocklistComponent.
    should "follow a layout's render tree to the blocklist" do
      found, = self.class.tree(UPSTREAM_VIEWS.join("layouts/default.html.erb"))
      assert(found.keys.any? { |file| file.to_s.end_with?("blocklist_component/blocklist_component.html.erb") }, found.keys.join("\n"))
      assert(found.keys.any? { |file| file.to_s.end_with?("modulation_navbar_component/modulation_navbar_component.html.erb") })
    end

    should "pass Modulation's skin, which is scoped, and find the unscoped rules in a component stylesheet" do
      assert_empty(self.class.unscoped(Rails.root.join("app/javascript/src/styles/zz_modulation_skin.scss"), "modulation"))
      assert_not_empty(self.class.unscoped(Rails.root.join("app/components/matrix_signin_component/matrix_signin_component.scss"), "modulation"))
    end
  end
end
