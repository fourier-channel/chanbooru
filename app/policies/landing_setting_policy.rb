# frozen_string_literal: true

# The front page is the site's shop window, so editing it is an admin act.
class LandingSettingPolicy < ApplicationPolicy
  def show?
    user.is_admin?
  end

  def update?
    show?
  end

  # The slide speed and the error page's pictures (the console's text box,
  # parsed and refused by LandingSetting). board, fresh_only and label were
  # the "new" row's target before the rows moved onto LandingCategory; nothing
  # reads them now, so accepting them would only let the console save a
  # setting that does nothing. See LandingSetting.
  def permitted_attributes
    %i[advance_ms error_page_post_ids_text]
  end
end
