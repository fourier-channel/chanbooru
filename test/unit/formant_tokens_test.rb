# frozen_string_literal: true

require "test_helper"

# chanbooru agrees with fourier-formant, checked rather than imported.
#
# Every other consumer imports the delivered token file. chanbooru cannot: its
# tokens live inside `@mixin modulation-theme`, applied at
# body[data-preset="modulation"], while the delivered file declares them on
# :root. Custom properties inherit, so importing it would hand Modulation's
# palette to the `historical` preset -- which exists to be the untouched
# upstream interface, and stops being that the moment it inherits our colours.
#
# The rule formant enforces is "names, not values, cross a boundary". Where the
# boundary cannot be crossed by an import, it is crossed by an assertion: the
# hydrated copy is the reference, this test is the link back to it, and a value
# edited on either side fails here instead of drifting silently for a month.
#
# That silence is the whole reason formant exists. fourier-sampling held eleven
# hand-copied tokens; nine matched and two did not, and nothing could have
# noticed, because both files were internally consistent and a copy holds no
# link back to what it copied. This test is that link.
class FormantTokensTest < ActiveSupport::TestCase
  CANON = Rails.root.join("app/javascript/src/styles/formant/_tokens.scss")
  PRESET_SOURCES = [
    Rails.root.join("app/javascript/src/styles/base/040_colors.scss"),
    Rails.root.join("app/javascript/src/styles/zz_modulation_skin.scss"),
  ].freeze

  DECL = /(--mod-[A-Za-z0-9_-]+)\s*:\s*([^;{}]+?)\s*;/

  # COMMENTS ARE NOT DECLARATIONS. Canon's prose names tokens the way prose
  # does -- "Pure white rather than --mod-ink: a pill sits on a tinted
  # ground..." -- and a scan that reads comments takes that sentence as
  # --mod-ink's value, runs on to the next semicolon, and swallows the real
  # --mod-tag-ink declaration with it. The later match wins in to_h, so the
  # comment overwrote the true --mod-ink and this test reported canon and the
  # fork disagreeing about a colour they both set to #e8e6e0.
  #
  # Block comments are CSS; line comments are SCSS, which every file read here
  # is compiled as. `(?<!:)` spares the `//` of a URL scheme. Replaced with a
  # space, not removed, so the text either side cannot fuse into a name.
  COMMENT = %r{/\*.*?\*/|(?<!:)//[^\n]*}m

  def parse(path)
    return {} unless File.exist?(path)

    parse_source(File.read(path))
  end

  def parse_source(source)
    source.gsub(COMMENT, " ").scan(DECL).to_h { |name, value| [name, value.split.join(" ")] }
  end

  # The widest scope wins. A component narrowing a token for itself -- the
  # creator gallery uses a larger radius under .modcreator -- is what tokens are
  # for, and is deliberately not compared here.
  def preset_tokens
    PRESET_SOURCES.reduce({}) { |acc, path| parse(path).merge(acc) }
  end

  context "The formant token file" do
    should "be present, because a consumer with no copy has nothing to check against" do
      assert(File.exist?(CANON), <<~MSG)
        #{CANON.relative_path_from(Rails.root)} is missing. It is hydrated from
        fourier-basis by `coherence hydrate`; if it never arrived, this checkout
        is not receiving canon and that is the thing to fix.
      MSG
    end

    should "agree with every token this fork defines at preset level" do
      canon = parse(CANON)
      preset = preset_tokens
      shared = canon.keys & preset.keys

      assert_operator(shared.size, :>, 5, "expected the preset and canon to share tokens; found #{shared.size}")

      disagreements = shared.filter_map do |name|
        "#{name}: this fork says #{preset[name]}, formant says #{canon[name]}" if preset[name] != canon[name]
      end

      assert_empty(disagreements, <<~MSG)
        A token means something different here than it does in canon.

        Whichever is right, they cannot both be: fix it in fourier-basis under
        docs/design/formant/, re-run `coherence hydrate`, and never by editing
        the delivered copy -- an edited copy is exactly the copy that drifts.
      MSG
    end

    # The shape canon actually has (formant tokens.css, the tag-ink note), cut
    # down. Against the comment-blind parser this read --mod-ink as a sentence
    # and never saw --mod-tag-ink at all.
    should "read declarations, never a token named in a comment" do
      source = <<~SCSS
        --mod-ink: #e8e6e0;
        /* Pure white rather than
         * --mod-ink: a pill sits on a tinted ground and the off-white read as
         * dim there. */
        --mod-tag-ink: #ffffff;
        // structure, and structure is --mod-accent: see above
        --mod-accent: #0ce92a;
        --mod-bg: url("https://example.invalid/x.png");
      SCSS

      assert_equal({ "--mod-ink" => "#e8e6e0", "--mod-tag-ink" => "#ffffff", "--mod-accent" => "#0ce92a",
                     "--mod-bg" => 'url("https://example.invalid/x.png")' }, parse_source(source))
    end
  end
end
