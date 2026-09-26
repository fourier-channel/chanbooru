# frozen_string_literal: true

require "test_helper"

# NO WHITE PAGE BETWEEN PAGES.
#
# Operator, 2026-09-26: "the booru is dropping to an empty white page when
# navigating between pages, then filling the content". Reproduced in Firefox
# (headless, the dev booru, signed in): every navigation painted one frame that
# was 100% white, 0.8-1.5s in. The head loads three parser-blocking scripts
# before the stylesheet, and until that stylesheet lands nothing tells the
# browser the page is dark, so it paints its default canvas -- white.
#
# `<meta name="color-scheme" content="dark">`, ahead of the scripts, removed
# the white frame from every navigation (whitest frame 0%). An inline html
# background did not (one navigation still went fully white), and would have
# put a colour VALUE in the layout where formant wants names. The historical
# preset is upstream's light interface and must not be told it is dark.
class ModulationColorSchemeTest < ActionDispatch::IntegrationTest
  def head_of(body)
    body[%r{<head>.*?</head>}m].to_s
  end

  context "A page's head" do
    should "declare the dark colour scheme under Modulation, before any script" do
      get posts_path(preset: "modulation")

      assert_response :success
      head = head_of(response.body)
      meta = head.index('<meta name="color-scheme" content="dark">')
      assert(meta, "no dark colour scheme declared in the Modulation head")
      assert_operator(meta, :<, head.index("<script").to_i, "declared after a script -- the browser paints before it reads it")
    end

    should "leave the historical preset's head as upstream's -- no colour scheme" do
      get posts_path(preset: "historical")

      assert_response :success
      assert_no_match(/name="color-scheme"/, head_of(response.body))
    end
  end
end
