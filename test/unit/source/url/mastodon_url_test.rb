require "test_helper"

module Source::Tests::URL
  class MastodonUrlTest < ActiveSupport::TestCase
    context "Mastodon URLs" do
      should be_image_url(
        "https://img.pawoo.net/media_attachments/files/001/297/997/small/c4272a09570757c2.png",
        "https://pawoo.net/media/lU2uV7C1MMQSb1czwvg",
      )

      should be_page_url(
        "https://pawoo.net/@evazion/19451018",
        "https://pawoo.net/web/statuses/19451018",
      )

      should be_profile_url(
        "https://pawoo.net/@evazion",
        "https://pawoo.net/users/esoraneko",
        "https://pawoo.net/web/accounts/47806",
      )

      should be_secondary_url(
        "https://pawoo.net/web/accounts/47806",
      )

      should_not be_secondary_url(
        "https://pawoo.net/@evazion",
        "https://pawoo.net/users/esoraneko",
      )

      should parse_url("https://pawoo.net/@evazion/19451018/").into(
        page_url: "https://pawoo.net/@evazion/19451018",
        username: "evazion",
        work_id: "19451018",
      )

      should parse_url("https://pawoo.net/web/statuses/19451018/favorites").into(
        page_url: "https://pawoo.net/web/statuses/19451018",
        username: nil,
        work_id: "19451018",
      )

      should parse_url("https://pawoo.net/@evazion/media").into(username: "evazion", page_url: nil)
      should parse_url("https://img.pawoo.net/media_attachments/files/001/297/997/original/c4272a09570757c2.png").into(page_url: nil)
    end

    should parse_url("https://img.pawoo.net/media_attachments/files/001/297/997/small/c4272a09570757c2.png").into(site_name: "Pawoo")
  end
end
