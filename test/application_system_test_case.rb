require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  include SystemTestHelper

  # Fork. Naming a Selenium browser runs Selenium Manager at once, and it asks
  # Mozilla for a browser when none is installed. Tests contact no outside site
  # (test/test_helpers/outside_site_helper.rb).
  FIREFOX = system("firefox --version", out: File::NULL, err: File::NULL)

  if FIREFOX
    driven_by :selenium, using: :headless_firefox, screen_size: [1400, 1400]
  else
    driven_by :rack_test
  end

  setup do
    skip "Firefox not installed" unless FIREFOX
  end
end
