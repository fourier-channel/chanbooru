# frozen_string_literal: true

require "test_helper"

# A post's applied view on one creator's page (operator 2026-11-01, item 8):
# flips, a pan, a scale and a stretch, saved per gallery and post so the view
# re-applies the next time that post is chosen. No row is the identity.
class CreatorGalleryPostViewTest < ActiveSupport::TestCase
  # The style cases post_view.js's test reads too, so the editor and the page
  # cannot draw one view two ways.
  FIXTURE = JSON.parse(Rails.root.join("test/fixtures/files/post_views.json").read)

  def view(**attrs)
    CreatorGalleryPostView.new(creator_gallery: @gallery, post_id: @post.id, **attrs)
  end

  context "A post view" do
    setup do
      @user = create(:user)
      @gallery = create(:creator_gallery, user: @user)
      @post = as(@user) { create(:post) }
    end

    should "default to the identity" do
      v = view
      v.save!
      v.reload

      assert_equal([false, false, 0, 0, 1000, 1000], [v.flip_h, v.flip_v, v.x, v.y, v.scale, v.stretch])
    end

    should "take every value at its range's ends" do
      assert_predicate(view(flip_h: true, flip_v: true, x: -1000, y: 1000, scale: 200, stretch: 500), :valid?)
      assert_predicate(view(x: 1000, y: -1000, scale: 4000, stretch: 2000), :valid?)
    end

    should "refuse a pan, scale or stretch out of range, naming the range" do
      { x: [-1001, 1001], y: [-1001, 1001], scale: [199, 4001], stretch: [499, 2001] }.each do |field, values|
        values.each do |value|
          v = view(field => value)

          assert_not(v.valid?, "#{field}=#{value} was accepted")
          assert_match(/between/, v.errors[field].join, "#{field}=#{value}")
        end
      end
    end

    should "refuse a fraction" do
      v = view(scale: 1000.5)

      assert_not(v.valid?)
      assert_predicate(v.errors[:scale], :present?)
    end

    should "refuse a flip that is neither on nor off" do
      v = view(flip_h: nil)

      assert_not(v.valid?)
      assert_predicate(v.errors[:flip_h], :present?)
    end

    should "be one row per gallery and post" do
      view.save!
      second = view(x: 10)

      assert_not(second.valid?)
      assert_raises(ActiveRecord::RecordNotUnique) { second.save!(validate: false) }
    end

    should "let another gallery keep its own view of the same post" do
      view.save!
      other = CreatorGalleryPostView.new(creator_gallery: create(:creator_gallery), post_id: @post.id, x: 10)

      assert_predicate(other, :valid?)
      other.save!
    end

    should "go with its gallery" do
      view(x: 5).save!
      assert_equal(1, @gallery.creator_gallery_post_views.count)

      @gallery.destroy!

      assert_equal(0, CreatorGalleryPostView.count)
    end

    should "hold the ranges the shared fixture holds" do
      assert_equal(FIXTURE["limits"], CreatorGalleryPostView::LIMITS.to_h { |field, range| [field.to_s, range.minmax] })
    end

    should "draw each shared view as the shared transform, and as --cg-view only when it is not the identity" do
      wrong = FIXTURE["views"].filter_map do |view, expected|
        got = CreatorGalleryPostView.transform(view&.symbolize_keys)
        "#{view.inspect}: wanted #{expected.inspect}, got #{got.inspect}" unless got == expected
      end

      assert_empty(wrong, wrong.join("\n"))
      assert(FIXTURE["views"].count { |_, expected| expected.present? } >= 6, "the fixture carries views that move")
      FIXTURE["views"].each do |view, expected|
        assert_equal(expected.present? ? "--cg-view: #{expected}" : "", CreatorGalleryPostView.style(view&.symbolize_keys))
      end
    end

    should "draw each shared harmonic picture as the shared style, the view composed about the card's centre" do
      wrong = FIXTURE["pictures"].filter_map do |picture, expected|
        got = CreatorGalleryPostView.picture_style(picture.deep_symbolize_keys)
        "#{picture.inspect}: wanted #{expected.inspect}, got #{got.inspect}" unless got == expected
      end

      assert_empty(wrong, wrong.join("\n"))
    end

    should "be drawn as a saved row draws it" do
      v = view(flip_v: true, x: 125, y: -333, scale: 1100, stretch: 1200)
      v.save!

      assert_equal({ flip_h: false, flip_v: true, x: 125, y: -333, scale: 1100, stretch: 1200 }, v.value)
      assert_equal("translate(12.5%, -33.3%) scale(1.32, -1.1)", CreatorGalleryPostView.transform(v.value))
      assert_equal(CreatorGalleryPostView::IDENTITY, view.value)
    end

    should "go with its gallery when the database deletes the gallery" do
      view(x: 5).save!
      CreatorGallery.where(id: @gallery.id).delete_all

      assert_equal(0, CreatorGalleryPostView.count)
    end
  end
end
