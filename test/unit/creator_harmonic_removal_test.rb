# frozen_string_literal: true

require "test_helper"

# A removal covers a link and what lies under it by whole path segments
# (CREATOR_TUNER.md sec 4.5), matched lowercased.
class CreatorHarmonicRemovalTest < ActiveSupport::TestCase
  setup do
    @admin = create(:admin_user)
  end

  def remove(url) = CreatorHarmonicRemoval.create!(url: url.downcase, removed_by: @admin)

  should "cover the link itself, what lies under it, and the link with a query" do
    remove("https://civitai.com/user/bad")
    urls = %w[
      https://civitai.com/user/bad https://civitai.com/user/bad/models https://civitai.com/user/bad?tab=models
      https://civitai.com/user/badger https://civitai.com/user/ba https://civitai.com/user
    ]

    assert_equal(Set.new(urls.first(3)), CreatorHarmonicRemoval.covering(urls))
  end

  should "match case-blind and hand back the links as given" do
    remove("https://civitai.com/user/Bad")

    assert_equal(Set["https://civitai.com/user/BAD/models"], CreatorHarmonicRemoval.covering(["https://civitai.com/user/BAD/models"]))
  end

  should "cover a whole site when its origin is removed" do
    remove("https://patreon.com")

    assert_equal(Set["https://patreon.com/dusk"], CreatorHarmonicRemoval.covering(["https://patreon.com/dusk", "https://ko-fi.com/dusk"]))
  end

  should "name every cut a removal could sit at" do
    assert_equal(
      %w[https://x.com/a/b?q=1 https://x.com/a/b https://x.com https://x.com/a],
      CreatorHarmonicRemoval.prefixes("https://x.com/A/b?q=1"),
    )
  end

  # The page carries the removals this way (harmonic_model.js fingerprint),
  # so it holds no list of what staff took down.
  should "fingerprint a link as the editor does" do
    assert_equal(%w[af63dc4c8601ec8c 6bcd98040aa60c8e], %w[a https://civitai.com/user/bad].map { |url| CreatorHarmonicRemoval.fingerprint(url) })
  end

  should "cover nothing when there are no removals" do
    assert_empty(CreatorHarmonicRemoval.covering(["https://x.com/dusk"]))
  end
end
