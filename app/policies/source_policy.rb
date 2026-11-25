# frozen_string_literal: true

class SourcePolicy < ApplicationPolicy
  # Fork: the page fetches the address it is given (SourceFetch).
  def show?
    SourceFetch.allowed?(user)
  end

  def denial_message(query)
    SourceFetch.refusal_message if query.to_s == "show?" && !show?
  end

  def rate_limit_for_show(**_options)
    { rate: 20.0 / 1.minute, burst: 50 }
  end
end
