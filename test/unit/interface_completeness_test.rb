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
#   7. every layout an interface draws, and the header slot it draws
#      (layouts/_navbar, where the layouts take their header from), reaches
#      #blacklist-box (the BlocklistComponent; without it blacklisted posts
#      are drawn) and the purge control, and a posts/show it draws reaches
#      the opened=1 request that writes the admin-view log.
# Not checked: that an interface's JS does nothing on another interface's
# pages (item 6). No shape of a file shows that.
#
# The other direction, core reaching into an interface, is a link: an
# interface's files can then not move, rename or go without breaking core.
# Core may not load a file from app/interfaces, name an interface's preset
# or component, or match a class only an interface draws (blacklists.js
# doing that is a privacy link: rename the card and blacklisted posts show).
# KNOWN_LINKS lists the ones core still has, each with the stage 2 step that
# cuts it (plan doc, "Stage 2" tab); a new link and a cut link left listed
# are both red.
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
  # Core: what the booru draws and decides with, outside app/interfaces.
  # app/logical/interface.rb is left out: its TABLE names each interface's
  # folder, which is how an interface is added, not a link.
  CORE_ROOTS = %w[app/javascript/src app/components app/views app/logical app/controllers app/helpers].freeze
  TABLE_FILE = Rails.root.join("app/logical/interface.rb")
  CLASS_NAME = /\A[a-zA-Z_][\w-]*\z/

  # The links core still has to an interface, by the stage 2 step that cuts
  # each: core file => what it reaches (".class", "preset <name>", "path
  # app/interfaces/<name>", or a component's class name). A step that cuts a
  # link deletes its entry in the same commit.
  KNOWN_LINKS = {
    "stage 2 step 1, the blacklist marker" => {
      "app/components/blocklist_component/blocklist_component.scss" => %w[.modgal-card],
      "app/javascript/src/javascripts/blacklists.js" => %w[.mod-flank-poolitem .modgal-card],
    },
    "stage 2 step 1b, error cards and creator lamps" => {
      "app/javascript/src/javascripts/creator_lamps.js" => %w[.mod-pill--cat-artist],
      "app/javascript/src/javascripts/error_card.js" => %w[.mod-image .modgal-thumb],
    },
    "stage 2 step 2, the hero band's JS comes home" => {
      "app/javascript/src/javascripts/creator_gallery_component.js" => ["path app/interfaces/modulation"],
      "app/components/modulation_landing_component/modulation_landing_component.scss" =>
        %w[.is-charging .is-lurching .is-offstage .is-popping .mod-cell .mod-cell-name .modland-credit-creator .modland-credit-platform .modland-warm],
      "app/javascript/src/styles/modulation/_stage.scss" =>
        %w[.has-view .is-failed .is-focus .is-incoming .is-offstage .is-tinting .mod-blog-cover .mod-blog-words .mod-cell .mod-cell-name .mod-image],
    },
    "stage 2 step 3, style partials and the theme" => {
      "app/components/modulation_landing_component/modulation_landing_component.scss" => %w[.mod-sortrow .mod-stage-center],
      "app/javascript/src/styles/base/040_colors.scss" => ["preset modulation"],
      "app/javascript/src/styles/modulation/_cards.scss" =>
        %w[.modgal-card .modgal-card--spoiler .modgal-card-artist .modgal-card-id .modgal-thumb .modgal-thumb--gated],
      "app/javascript/src/styles/modulation/_pill.scss" => %w[.mod-pill-count],
      "app/javascript/src/styles/modulation/_stage.scss" =>
        %w[.is-blocked .is-current .is-empty .is-enter-next .is-enter-prev .is-nav-next .is-nav-prev .is-spoiler .is-windowed
           .mod-flank-col .mod-flank-col--next .mod-flank-col--prev .mod-frame .mod-image--placeholder .mod-sortrow
           .mod-sortrow-tag .mod-spoiler .mod-stage-center .mod-trailcap .mod-trailcap-label],
    },
    "stage 2 step 5, view transitions" => {
      "app/javascript/src/styles/common/view_transitions.scss" => %w[.modgal-tagpill],
    },
    "stage 2 step 6, creator galleries become Modulation pages (boo.120)" => {
      "app/components/creator_gallery_component/creator_gallery_component.scss" => [".is-blocked", "preset modulation"],
    },
  }.freeze

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

  # The rules in a stylesheet that are not under body[data-preset="<name>"]
  # or :where() of it (the same scope, adding no specificity), as
  # "file:line: selector". A rule inside a scoped rule, a @mixin, a
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
        found << "#{file.relative_path_from(Rails.root)}:#{line}: #{prelude.squish}" unless selectors.all? { |s| s.start_with?(scope, ":where(#{scope})", "%") }
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
      layout = (k.start_with?("layouts/") && k.exclude?("/_")) || k == "layouts/_navbar"
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

  # A file's text without its comments, line numbers kept: a comment that
  # names an interface's file or class is not a link.
  def self.code(file)
    text = file.read
    case file.extname
    when ".js", ".mjs", ".scss" then text.gsub(%r{/\*.*?\*/}m) { |c| "\n" * c.count("\n") }.gsub(%r{(^|[^:"'\\])//[^\n]*}, '\1')
    when ".erb" then text.gsub(/<%#.*?%>/m) { |c| "\n" * c.count("\n") }
    when ".rb" then text.gsub(/^\s*#[^\n]*/, "")
    else text
    end
  end

  # The class names files put on elements: every word in a template or
  # component (a class may be built in Ruby), and in JS the class attributes
  # it writes and the classes it adds, removes or toggles.
  def self.emitted(files)
    files.flat_map do |file|
      text = code(file)
      if file.extname.in?([".erb", ".rb"])
        text.scan(/[a-zA-Z_][\w-]*/)
      else
        text.scan(/class(?:Name)?\s*[=:]\s*\\?["'`]([^"'`]*)/).flatten.flat_map(&:split) +
          text.scan(/(?:classList\.(?:add|remove|toggle)|(?:add|remove|toggle)Class)\(([^)]*)\)/).flatten.flat_map { |args| args.scan(/["'`]([\w-]+)["'`]/).flatten }
      end
    end.grep(CLASS_NAME).to_set
  end

  # Every link from core files into the interfaces, as
  # {[core file, what it reaches] => the gap, with its fix}.
  def self.links(interfaces, core_files)
    rel = ->(file) { file.relative_path_from(Rails.root).to_s }
    drawing = interfaces.index_with { |interface| interface.folder.glob("**/*.{erb,rb,js,mjs}").select(&:file?) }
    core_classes = emitted(core_files.select { |file| file.extname.in?([".erb", ".rb", ".js", ".mjs"]) })
    owners = drawing.flat_map { |interface, files| (emitted(files) - core_classes).map { |name| [name, interface] } }.group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
    components = drawing.flat_map { |interface, files| files.select { |f| f.extname == ".rb" && f.dirname.basename.to_s == "components" }.map { |f| [f.basename(".rb").to_s.camelize, interface] } }

    core_files.reject { |file| file == TABLE_FILE }.each_with_object({}) do |file, found|
      text = code(file)
      where = rel[file]
      interfaces.each do |interface|
        name = interface.name
        folder = "app/interfaces/#{name}"
        if text.match?(%r{["'`][^"'`\n]*interfaces/#{name}(?:/|["'`])})
          found[[where, "path #{folder}"]] = "#{where} loads a file from #{folder}; fix: move what core needs into core, so the interface reaches core and never the other way"
        end
        if file.extname.in?([".js", ".mjs", ".scss"]) && text.match?(/data-preset=["']?#{name}\b|preset\s*[!=]==?\s*["']#{name}["']/)
          found[[where, "preset #{name}"]] = "#{where} names the #{name} preset; fix: move the rule into #{folder}/stylesheets or #{folder}/javascript"
        end
      end
      if file.extname.in?([".rb", ".erb"])
        components.each do |klass, interface|
          next unless text.match?(/\b#{klass}\b/)

          found[[where, klass]] = "#{where} names #{klass}, a component of interface #{interface.name}; fix: render it from the interface's own views, or move what core needs into core"
        end
      end
      next unless file.extname.in?([".js", ".mjs", ".scss"])

      if file.extname == ".scss"
        references = text.scan(/(?<![\w-])\.([a-zA-Z_][\w-]*)/).flatten
      else
        references = text.scan(/"[^"\n]*"|'[^'\n]*'|`[^`]*`/).flat_map { |s| s.scan(/(?<![\w-])\.([a-zA-Z_][\w-]*)/).flatten } +
          text.scan(/(?:classList\.contains|hasClass)\(\s*["']([\w-]+)["']/).flatten
      end
      references.uniq.select { |name| owners.key?(name) }.each do |name|
        found[[where, ".#{name}"]] = "#{where} matches .#{name}, a class only interface #{owners[name].map(&:name).join(", ")} draws; " \
                                     "fix: give the element a marker core owns and match that, or move the rule into the interface"
      end
    end
  end

  def self.core_files
    CORE_ROOTS.flat_map { |root| Rails.root.join(root).glob("**/*.{js,mjs,scss,erb,rb}") }.select(&:file?)
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

    should "be reached from core by the known links only, each listed until its step cuts it" do
      found = self.class.links(Interface::TABLE.reject(&:classic?), self.class.core_files)
      known = KNOWN_LINKS.flat_map { |step, files| files.flat_map { |file, reached| reached.map { |what| [[file, what], step] } } }.to_h
      new_links = found.except(*known.keys).values
      cut = known.except(*found.keys).map do |(file, what), step|
        "#{file} no longer reaches #{what}, and KNOWN_LINKS still lists it under #{step.inspect}; fix: delete that entry"
      end
      assert_empty(new_links + cut, "core and the interfaces:\n#{(new_links + cut).join("\n")}")
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

    should "name a layout or header slot that never reaches #blacklist-box or purge, and a post page that never sends opened=1" do
      gaps = self.class.gaps(self.class.fixture("dutiless", draws: ["layouts/default", "layouts/_navbar", "posts/show"]))
      %w[default _navbar].each do |layout|
        assert(gaps.any? { |gap| gap.include?("layouts/#{layout}.html.erb never reaches #blacklist-box") }, gaps.join("\n"))
        assert(gaps.any? { |gap| gap.include?("layouts/#{layout}.html.erb never reaches the purge control") }, gaps.join("\n"))
      end
      assert(gaps.any? { |gap| gap.include?("posts/show.html.erb never sends the opened=1 request") }, gaps.join("\n"))
    end

    # The follower is what the duty checks stand on: from upstream's own
    # default layout, through the header slot, it must reach each header's
    # BlocklistComponent -- upstream's slot alone, and Modulation's copy
    # first when it is handed Modulation's views.
    should "follow a layout's render tree through the header slot to the blocklist" do
      default = UPSTREAM_VIEWS.join("layouts/default.html.erb")
      [[nil, "/navbar_component/navbar_component.html.erb"],
       [Interface.fetch("modulation").folder.join("views"), "/modulation_navbar_component/modulation_navbar_component.html.erb"]].each do |views, header|
        found, = self.class.tree(default, views: views)
        assert(found.keys.any? { |file| file.to_s.end_with?(header) }, "#{header} not reached:\n#{found.keys.join("\n")}")
        assert(found.keys.any? { |file| file.to_s.end_with?("blocklist_component/blocklist_component.html.erb") }, found.keys.join("\n"))
      end
    end

    should "name a core file that loads, names or matches what only an interface has, and not a class core draws too" do
      core = CHECKLIST.join("core").glob("**/*.{js,mjs,scss,erb,rb}")
      found = self.class.links([self.class.fixture("linked")], core)
      js = "test/files/interfaces/checklist/core/javascript/linked.js"
      scss = "test/files/interfaces/checklist/core/stylesheets/linked.scss"
      rb = "test/files/interfaces/checklist/core/components/linked_frame_component.rb"
      expected = [[js, "path app/interfaces/linked"], [js, ".linked-card"], [js, "preset linked"], [scss, ".linked-card"], [scss, "preset linked"], [rb, "LinkedCardComponent"]]
      assert_equal(expected.sort, found.keys.sort, found.values.join("\n"))
      assert(found.values.all? { |gap| gap.include?("fix:") }, found.values.join("\n"))
    end

    should "pass Modulation's skin and its components, which are scoped, and find the unscoped rules in a core component stylesheet" do
      Interface.fetch("modulation").folder.glob("{stylesheets,components}/**/*.scss").each { |file| assert_empty(self.class.unscoped(file, "modulation"), file.to_s) }
      assert_not_empty(self.class.unscoped(Rails.root.join("app/components/blocklist_component/blocklist_component.scss"), "modulation"))
    end
  end
end
