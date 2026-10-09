require "test_helper"

# The Sample link is the only route into the curation surface from inside this
# site, and from inside Technetium there is no other way in at all. If it does
# not render for the owner, the surface is unreachable for the one person
# entitled to it -- so this renders a REAL page in a REAL request and looks at
# the HTML, rather than testing the predicate in isolation.
#
# BOTH PRESETS, and that is the point of this file. chanbooru renders one of
# two navbars -- ModulationNavbarComponent is the live one, NavbarComponent is
# upstream's, kept for side-by-side testing -- and the TEST environment
# defaults to the historical preset while production defaults to modulation.
# An earlier version of this test asserted only the default and passed against
# the navbar nobody sees, while the live one showed an inert, greyed-out pill.
# A test that renders a different skin than production is not a test of
# production.
#
# THE SURFACE MOVED (operator ruling 2026-10-09): from /sample on this site to
# its own host, sample.41chan.net, with the old paths retired rather than
# redirected. The link is Danbooru.config.fourier_sample_url, absolute, and it
# navigates the SAME frame ("be absolutely sure that calling sample from
# within the booru from within sample doesn't cause a cascade").
class NavbarSampleLinkTest < ActionDispatch::IntegrationTest
  # ?preset= is explicit and sticky for the session, which is how a test reaches
  # the skin it means to check rather than the one it inherits.
  #
  # Defined at CLASS level on purpose: shoulda-context instance_execs its
  # `should` blocks, so a `def` written inside `context` is not an instance
  # method and every test errors with NoMethodError.
  def nav_for(user, preset)
    if user
      get_auth root_path(preset: preset), user
    else
      get root_path(preset: preset)
    end
    assert_response :success
    response.body
  end

  def sample_host
    URI.parse(Danbooru.config.fourier_sample_url).host
  end

  # Every anchor on the page pointing at the sampling host, parsed rather than
  # regex-matched so an attribute anywhere on the tag is seen.
  def sample_anchors(body)
    Nokogiri::HTML5(body).css("a[href]").select do |a|
      URI.parse(a["href"]).host == sample_host
    rescue URI::InvalidURIError
      false
    end
  end

  context "the Sample nav link" do
    setup do
      @owner = travel_to(1.month.ago) { create(:owner_user) }
      @admin = travel_to(1.month.ago) { create(:admin_user) }
      @member = travel_to(1.month.ago) { create(:user) }
    end

    should "be an absolute https address on another host, not a path on this one" do
      url = URI.parse(Danbooru.config.fourier_sample_url)

      assert_equal("https", url.scheme)
      assert_equal("sample.41chan.net", url.host)
      assert_equal("/", url.path)
    end

    %w[modulation historical].each do |preset|
      should "render for the owner in the #{preset} navbar, at the configured address" do
        anchors = sample_anchors(nav_for(@owner, preset))

        assert_equal(1, anchors.size, "the owner must have exactly one way into the curation surface in #{preset}")
        assert_equal(Danbooru.config.fourier_sample_url, anchors.first["href"])
      end

      # The cascade guard on the booru's side. A link with no target, no rel
      # opening a new context and no script hook navigates the frame it is in:
      # inside Technetium, the booru's frame becomes sample's, and sample's way
      # back makes it the booru's again. Anything here that opened a new
      # browsing context, or aimed at the parent or top, is the start of a
      # cascade, so every attribute that could do it is refused by name.
      should "navigate the same frame in the #{preset} navbar" do
        anchor = sample_anchors(nav_for(@owner, preset)).first

        assert_not_nil(anchor)
        assert_nil(anchor["target"], "a target would leave the frame the booru is in")
        assert_no_match(/noopener|noreferrer|external/, anchor["rel"].to_s)
        assert_empty(anchor.attributes.keys.grep(/\Aon|\Adata-(remote|method|turbo)/),
                     "no script hook may take over the click")
      end

      should "follow the setting, so the address is written once, in the #{preset} navbar" do
        Danbooru.config.stubs(:fourier_sample_url).returns("https://elsewhere.example/")

        assert_match(%r{href="https://elsewhere\.example/"}, nav_for(@owner, preset))
      end

      should "not link the retired /sample path in the #{preset} navbar" do
        assert_no_match(%r{href="/sample}, nav_for(@owner, preset))
      end

      should "not render for an admin in the #{preset} navbar" do
        assert_empty(sample_anchors(nav_for(@admin, preset)))
      end

      should "not render for an ordinary member in the #{preset} navbar" do
        assert_empty(sample_anchors(nav_for(@member, preset)))
      end

      should "not render for an anonymous visitor in the #{preset} navbar" do
        assert_empty(sample_anchors(nav_for(nil, preset)))
      end
    end

    # The other half of "no cascade" that the booru owns: it must not be
    # embeddable BY the sampling host. Sample links back here in the same
    # frame; if it ever framed the booru instead, each round trip would add a
    # level. The booru's frame-ancestors is what refuses that, whatever sample
    # does. Read off the real header, built at boot from the running config.
    should "not let the sampling host frame the booru" do
      get root_path
      csp = response.headers["Content-Security-Policy"].to_s

      assert_match(/frame-ancestors/, csp)
      assert_not_includes(csp, sample_host)
    end

    should "not embed the sampling surface in a frame on any booru page" do
      body = nav_for(@owner, "modulation")
      framed = Nokogiri::HTML5(body).css("iframe, frame, object, embed").select { |el| el.to_html.include?(sample_host) }

      assert_empty(framed)
    end

    should "not ship an inert Sample pill any more" do
      # It was deliberately disabled until the surface was integrated. That
      # condition was met when the trailing-slash redirect landed, and a pill
      # that stays greyed after its stated blocker is gone is worse than no
      # pill: it reads as "broken" rather than "not yet".
      body = nav_for(@owner, "modulation")

      assert_no_match(/Not yet linked/, body)
    end
  end

  # The booru's half of the old /sample gate is gone with the old paths
  # (ruling 2026-10-09, "Retire them"): the proxy's owner check asked
  # /fourier_sample_authorize, and nothing asks it now. No fallback is kept,
  # so the path answers like any other unknown one.
  context "the retired owner check" do
    should "no longer be routed" do
      assert_not(Rails.application.routes.url_helpers.respond_to?(:fourier_sample_authorize_path))
      assert_not(Rails.application.routes.routes.any? { |r| r.defaults[:controller] == "sample" })
    end

    should "answer not found, even for the owner who used to pass it" do
      get_auth "/fourier_sample_authorize", travel_to(1.month.ago) { create(:owner_user) }

      assert_response 404
      assert_nil(response.headers["X-Fourier-View"], "nothing on the booru names a sampling view any more")
    end
  end
end
