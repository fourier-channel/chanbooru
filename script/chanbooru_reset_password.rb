# frozen_string_literal: true

# Reset one booru account's password and print the one-time link that shows
# it to the person (PasswordReveal; operator rulings 2026-10-19). Run inside
# the danbooru container by bin/chanbooru-reset-password:
#
#   bin/rails runner script/chanbooru_reset_password.rb -- <booru name>
#
# Prints the account, the link, when it stops working and what to do with it.
# Never the password: the administrator running this is not to see it, only
# the person who opens the link.

args = ARGV.reject { |arg| arg == "--" }
if args.size != 1 || args.first.blank?
  warn "FAIL: give exactly one booru account name (got #{args.size})."
  warn "fix: bin/chanbooru-reset-password <booru name>"
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
  issued = PasswordReveal.new.reset!(user)
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
puts "link:     #{link}"
puts "expires:  #{issued.expires_at.strftime("%Y-%m-%d %H:%M UTC")} (in #{ActionController::Base.helpers.distance_of_time_in_words(Time.now.utc, issued.expires_at)})"
puts "sessions: ended #{issued.sessions_ended} booru login session(s)"
puts "note:     2FA is on for this account; signing in still needs its authenticator code or a backup code." if user.totp.present?
puts "note:     its #{user.api_keys.count} API key(s) still work; remove them on its API keys page if the account was taken over." if user.api_keys.exists?
puts "Send the link to #{user.name} privately (a direct message, never a room). It shows the password once, then stops working."
