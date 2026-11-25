# frozen_string_literal: true

# Marks a client whose requests go to an address somebody chose, and refuses
# them unless the site may fetch for that account (see SourceFetch). Runs before
# every request, and raises, so nothing is looked up or sent.
module Danbooru
  class Http
    class RequestedBy < HTTP::Feature
      attr_reader :user

      def initialize(user:)
        super()
        @user = user
      end

      def self.register
        HTTP::Options.register_feature :requested_by, self
      end

      def perform(request)
        SourceFetch.refuse!(user)
        yield request
      end
    end
  end
end
