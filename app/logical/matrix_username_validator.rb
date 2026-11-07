# frozen_string_literal: true

# Fork: a booru name that is the username of a 41chan Matrix account belongs to
# that Matrix account (operator, 2026-11-07). Its owner gets the booru account
# of that name on their first booru visit (MatrixAccount); a signup or a rename
# that takes the name first would leave them a "taken" name they never chose
# to give up. So a new name that is someone else's Matrix username is refused.
#
# The homeserver is asked, through its profile API: 404 means no such Matrix
# account. Any other answer refuses the name, because a name that cannot be
# checked cannot be handed out safely, and the log says what to fix. Names are
# compared lowercased, as booru names are. A name no Matrix username can be
# (one with CJK in it) is never asked about, nor one already refused for
# another reason.
#
# @example
#   validates :name, matrix_username: true
class MatrixUsernameValidator < ActiveModel::EachValidator
  TIMEOUT = 5
  LOCALPART = %r{\A[a-z0-9._=\-/+]+\z}

  def validate_each(rec, attr, name)
    return unless Danbooru.config.matrix_accounts_from_identity?
    return if rec.errors.include?(attr) || !name.to_s.downcase.match?(LOCALPART)

    matrix_id = "@#{name.downcase}:#{Danbooru.config.fourier_matrix_server_name}"
    user = rec.is_a?(UserNameChangeRequest) ? rec.user : rec
    return if user.matrix_id == matrix_id

    origin = Danbooru.config.fourier_media_origin.presence&.chomp("/")
    token = Danbooru.config.fourier_matrix_profile_token.presence
    if origin && token
      url = "#{origin}/_matrix/client/v3/profile/#{ERB::Util.url_encode(matrix_id)}"
      code = Danbooru::Http.internal.timeout(TIMEOUT).headers(Accept: "application/json", Authorization: "Bearer #{token}").get(url).code
    end

    if code == 200
      rec.errors.add(attr, "belongs to a 41chan Matrix account, and only that account can have it: choose another name, or, if it is your own Matrix username, sign in with Matrix and the booru account of that name is made for you")
    elsif code != 404
      if origin.nil? || token.nil?
        remedy = "set fourier_media_origin and DANBOORU_FOURIER_MATRIX_PROFILE_TOKEN (.env.local)"
      elsif code.in?([401, 403])
        remedy = "the homeserver refused the profile reader's token: set DANBOORU_FOURIER_MATRIX_PROFILE_TOKEN in .env.local to a live access token"
      else
        remedy = "check that fourier_media_origin reaches the homeserver's client API"
      end
      Rails.logger.warn("matrix username check: could not ask the homeserver whether a name is a Matrix username (#{code ? "HTTP #{code}" : "not configured"}); every new name it is asked about is refused until #{remedy}")
      rec.errors.add(attr, "can't be checked against 41chan Matrix usernames right now, so it can't be given out: try again in a few minutes, and if it keeps failing, tell the site staff that the Matrix username check is down")
    end
  end
end
