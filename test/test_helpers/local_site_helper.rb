# Fork. Servers on this machine standing in for the outside sites upstream's
# HTTP tests fetched (operator ruling 2026-11-24, outside_site_helper.rb).
module LocalSiteHelper
  # A small HTTP/1.1 server. WEBrick cannot stand in here: it refuses the raw
  # characters some of these tests put in a URL.
  #
  # The block answers a request with [status, headers, body]. A body that is
  # not a string is sent piece by piece, in chunks unless the answer has a
  # Content-Length.
  class LocalSite
    Request = Struct.new(:verb, :target, :headers, :body)

    attr_reader :requests

    def initialize(address: "127.0.0.1", host: address, tls: nil, &answer)
      @server = TCPServer.new(address, 0)
      @host = host
      @tls = tls
      @answer = answer
      @requests = []
      @clients = []
      @thread = Thread.new { loop { accept } }
    end

    def url(path = "")
      "#{@tls ? "https" : "http"}://#{@host}:#{@server.local_address.ip_port}/#{path}"
    end

    def stop
      [@thread, *@clients].each(&:kill).each(&:join)
      @server.close
    end

    private

    def accept
      client = @server.accept
      @clients << Thread.new { serve(client) }
    end

    def serve(client)
      socket = @tls ? OpenSSL::SSL::SSLSocket.new(client, @tls).tap(&:accept) : client
      request = read_request(socket)
      return if request.nil?

      requests << request
      write_answer(socket, request, *@answer.call(request))
    rescue SystemCallError, IOError, OpenSSL::SSL::SSLError
      # The client hung up: a timeout, a size limit or a refused certificate.
    ensure
      client.close
    end

    def read_request(socket)
      verb, target, = socket.gets("\r\n")&.split
      return if target.nil?

      headers = {}
      while (line = socket.gets("\r\n")&.chomp("\r\n")).present?
        name, value = line.split(":", 2)
        headers[name] = value.strip
      end
      Request.new(verb, target, headers, socket.read(headers["Content-Length"].to_i))
    end

    def write_answer(socket, request, status, headers, body)
      headers = { "Content-Type" => "text/plain", **headers, "Connection" => "close" }
      if body.is_a?(String)
        headers["Content-Length"] ||= body.bytesize
      elsif headers["Content-Length"].nil?
        headers["Transfer-Encoding"] = "chunked"
      end

      socket.write("HTTP/1.1 #{status} #{Rack::Utils::HTTP_STATUS_CODES[status]}\r\n")
      socket.write("#{headers.map { |name, value| "#{name}: #{value}\r\n" }.join}\r\n")
      return if request.verb == "HEAD"

      chunked = headers.key?("Transfer-Encoding")
      (body.is_a?(String) ? [body] : body).each do |piece|
        socket.write(chunked ? "#{piece.bytesize.to_s(16)}\r\n#{piece}\r\n" : piece)
        socket.flush
      end
      socket.write("0\r\n\r\n") if chunked
    end
  end

  # What httpbin answers, for the paths these tests ask.
  HTTPBIN = lambda do |request|
    base = "http://#{request.headers["Host"]}"
    path, query = request.target.split("?", 2)
    json = ->(value) { [200, { "Content-Type" => "application/json" }, value.to_json] }
    to = ->(url, headers = {}) { [302, { "Location" => url, **headers }, ""] }

    case path.sub(%r{\A/+}, "/")
    when %r{\A/status/(\d+)\z}
      [$1.to_i, {}, ""]
    when %r{\A/absolute-redirect/(\d+)\z}
      to.call($1.to_i > 1 ? "#{base}/absolute-redirect/#{$1.to_i - 1}" : "#{base}/get")
    when "/redirect-to"
      to.call(URI.decode_www_form(query).to_h.fetch("url"))
    when %r{\A/delay/(\d+)\z}
      sleep($1.to_i)
      json.call({})
    when "/drip"
      params = URI.decode_www_form(query).to_h
      bytes = params["numbytes"].to_i
      [200, { "Content-Length" => bytes }, Enumerator.new { |y| bytes.times { y << "*" and sleep(params["duration"].to_f / bytes) } }]
    when "/html"
      [200, { "Content-Type" => "text/html; charset=utf-8" }, "<!DOCTYPE html><html><body><h1>Herman Melville - Moby-Dick</h1></body></html>"]
    when "/xml"
      [200, { "Content-Type" => "application/xml" }, %{<?xml version="1.0"?><slideshow title="Sample"><slide><title>One</title></slide></slideshow>}]
    when "/cookies"
      json.call({ cookies: request.headers["Cookie"].to_s.split("; ").to_h { |cookie| cookie.split("=", 2) } })
    when "/cookies/set"
      to.call("#{base}/cookies", { "Set-Cookie" => "#{query}; Path=/" })
    when %r{\A/bytes/(\d+)\z}
      [200, { "Content-Type" => "application/octet-stream" }, "\0" * $1.to_i]
    when %r{\A/stream-bytes/(\d+)\z}
      [200, { "Content-Type" => "application/octet-stream" }, ("\0" * $1.to_i).scan(/.{1,100}/m)]
    when "/uuid"
      json.call({ uuid: SecureRandom.uuid })
    when "/get", "/post", %r{\A/anything/?}
      json.call({ url: "#{base}#{request.target}", headers: request.headers.transform_values { |value| [value] } })
    else
      [404, {}, ""]
    end
  end

  # Start a site, stopped when the test ends.
  def local_site(**options, &answer)
    LocalSite.new(**options, &answer).tap { |site| local_sites << site }
  end

  def httpbin
    @httpbin ||= local_site(&HTTPBIN)
  end

  # Yields a lambda that starts an https site on localhost, whose certificate
  # comes from an authority trusted inside the block unless said otherwise.
  def with_certificate_authority
    ca_key = OpenSSL::PKey::EC.generate("prime256v1")
    ca = certificate("Test CA", key: ca_key, ca: true)
    store = OpenSSL::X509::Store.new.add_cert(ca)

    stub_const(OpenSSL::SSL::SSLContext, :DEFAULT_CERT_STORE, store) do
      yield(lambda do |host: "localhost", expires: 1.hour.from_now, self_signed: false|
        key = OpenSSL::PKey::EC.generate("prime256v1")
        cert = certificate(host, key:, expires:, **(self_signed ? {} : { issuer: ca, issuer_key: ca_key }))
        tls = OpenSSL::SSL::SSLContext.new.tap { |context| context.add_certificate(cert, key) }
        local_site(host: "localhost", tls:) { [200, {}, ""] }.url
      end)
    end
  end

  # A name that gives no address, as TCPSocket answers it.
  def stub_no_such_host(host)
    TCPSocket.stubs(:open).with { |name, *| name == host }.raises(SocketError, "getaddrinfo: Name or service not known")
  end

  def after_teardown
    super
  ensure
    local_sites.each(&:stop).clear
  end

  private

  def local_sites
    @local_sites ||= []
  end

  def certificate(name, key:, expires: 1.hour.from_now, issuer: nil, issuer_key: key, ca: false)
    OpenSSL::X509::Certificate.new.tap do |cert|
      cert.version = 2
      cert.serial = SecureRandom.random_number(1 << 64)
      cert.subject = OpenSSL::X509::Name.new([["CN", name]])
      cert.issuer = issuer&.subject || cert.subject
      cert.public_key = key
      cert.not_before = 2.days.ago
      cert.not_after = expires

      extensions = OpenSSL::X509::ExtensionFactory.new
      cert.add_extension(extensions.create_extension("basicConstraints", "CA:#{ca.to_s.upcase}", true))
      cert.add_extension(extensions.create_extension("subjectAltName", "DNS:#{name}")) unless ca
      cert.sign(issuer_key, "SHA256")
    end
  end
end
