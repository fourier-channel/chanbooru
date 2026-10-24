# frozen_string_literal: true

# Reset one booru account's password and print the one-time link that shows
# it to the person (PasswordReveal; operator rulings 2026-10-19). Run inside
# the danbooru container by bin/chanbooru-reset-password:
#
#   bin/rails runner script/chanbooru_reset_password.rb -- <booru name>
#   bin/rails runner script/chanbooru_reset_password.rb -- <booru name> --matrix <matrix user>  < password
#   bin/rails runner script/chanbooru_reset_password.rb -- --drop-matrix  < token
#
# Prints the account, the link, when it stops working and what to do with it.
# Never a password: the administrator running this is not to see one, only
# the person who opens the link.
#
# --matrix seals a SECOND password in the same link, for the person's Matrix
# account. MAS is not reachable from this container, so the host script makes
# that password, hands it in on stdin (never argv, which `ps` shows), and sets
# it in MAS itself once this has printed the link. When MAS refuses it, the
# host runs --drop-matrix with the link's token on stdin, and the link goes on
# showing the booru password alone.

# Locals, not constants: the tests load this file once per case.
matrix_server = Danbooru.config.fourier_matrix_server_name
# A MAS username: lowercase, and never starting with "-", which mas-cli would
# read as an option.
matrix_localpart = /\A[a-z0-9][a-z0-9._=-]*\z/

args = ARGV.reject { |arg| arg == "--" }

if args == ["--drop-matrix"]
  token = $stdin.read.to_s.strip
  begin
    if PasswordReveal.new.drop!(token, "matrix")
      puts "dropped:  the link no longer holds a Matrix password; it still shows the booru one."
      exit 0
    end
    warn "FAIL: no live link with a Matrix password matches that token -- it is expired, already shown, or was never one."
  rescue PasswordReveal::Error => e
    warn "FAIL: #{e.message}"
  end
  warn "fix: do not send the link. Run bin/chanbooru-reset-password again; a new link replaces it."
  exit 1
end

matrix = nil
if (at = args.index("--matrix"))
  given = args[at + 1].to_s
  args = args[0...at] + args[(at + 2)..].to_a
  localpart, server = given.delete_prefix("@").split(":", 2)
  if server.present? && server != matrix_server
    warn "FAIL: #{given.inspect} is an account on #{server}, and this server's MAS only holds accounts on #{matrix_server}. Nothing was changed."
    warn "fix: give the Matrix username on #{matrix_server}, as @name:#{matrix_server} or just name."
    exit 2
  end
  unless localpart.to_s.match?(matrix_localpart)
    warn "FAIL: #{given.inspect} is not a Matrix username here (lowercase letters, digits and . _ = -, starting with a letter or digit). Nothing was changed."
    warn "fix: copy it from the person's Matrix ID, the part between @ and :#{matrix_server}."
    exit 2
  end
  matrix = { label: "matrix", account: "@#{localpart}:#{matrix_server}", password: $stdin.read.to_s.strip }
end

if args.size != 1 || args.first.blank? || args.first.start_with?("--")
  warn "FAIL: give exactly one booru account name, and --matrix <matrix user> at most once (got #{ARGV.reject { |arg| arg == "--" }.inspect})."
  warn "fix: bin/chanbooru-reset-password <booru name> [--matrix <matrix user>]"
  exit 2
end

name = args.first
user = User.find_by_name(name)
if user.nil?
  warn "FAIL: no booru account is named #{name.inspect}."
  warn "fix: check the spelling against the name on the account's profile page; case does not matter, and a space is the same as an underscore."
  exit 1
end

# Every way the reset can stop ends in a sentence and a fix, not a backtrace.
# Each is a reset that undid itself: the password change rolls back and the
# sealed copy is removed (PasswordReveal#reset!).
begin
  issued = PasswordReveal.new.reset!(user, also: [matrix].compact)
rescue PasswordReveal::Error => e
  warn "FAIL: #{e.message}"
  exit 1
rescue ActiveRecord::RecordInvalid => e
  warn "FAIL: #{user.name} (##{user.id}) could not be saved with a new password: #{e.record.errors.full_messages.join("; ")}. Nothing was changed."
  warn "fix: correct those fields on the account from a Rails console in the danbooru container (every save checks them), then run this again."
  exit 1
rescue StandardError => e
  warn "FAIL: #{e.class}: #{e.message}"
  warn "fix: nothing was changed. Deal with the cause the error names, then run this again."
  exit 1
end

link = "#{Danbooru.config.canonical_url}#{Rails.application.routes.url_helpers.edit_password_reset_path(reveal: issued.token)}"
puts "account:  #{user.name} (##{user.id})"
puts "matrix:   #{matrix[:account]}" if matrix
puts "link:     #{link}"
puts "expires:  #{issued.expires_at.strftime("%Y-%m-%d %H:%M UTC")} (in #{ActionController::Base.helpers.distance_of_time_in_words(Time.now.utc, issued.expires_at)})"
puts "sessions: ended #{issued.sessions_ended} booru login session(s)"
puts "note:     2FA is on for this account; signing in still needs its authenticator code or a backup code." if user.totp.present?
puts "note:     its #{user.api_keys.count} API key(s) still work; remove them on its API keys page if the account was taken over." if user.api_keys.exists?
puts "Send the link to #{user.name} privately (a direct message, never a room). It shows the password#{"s" if matrix} once, then stops working."
