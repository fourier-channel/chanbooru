# Fork. The mail servers the outside resolver gives, stubbed: no test contacts
# an outside site (operator ruling 2026-11-24, outside_site_helper.rb).
module EmailTestHelper
  MAIL_SERVERS = {
    "danbooru.donmai.us" => "mx.danbooru.donmai.us",
    "gmail.com" => "gmail-smtp-in.l.google.com",
  }.freeze

  # Any other domain has no mail server.
  def stub_mail_servers
    mx = Resolv::DNS::Resource::IN::MX
    Resolv::DNS.any_instance.stubs(:getresource).with { |domain, type| type == mx && !MAIL_SERVERS.key?(domain) }.raises(Resolv::ResolvError)
    MAIL_SERVERS.each do |domain, server|
      Resolv::DNS.any_instance.stubs(:getresource).with(domain, mx).returns(mx.new(10, Resolv::DNS::Name.create("#{server}.")))
    end
  end
end
