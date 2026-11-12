# frozen_string_literal: true

module DungeonCritters
  module Online
    class VersionedApiClient
      def initialize(transport)
        @transport = transport
      end

      def leaderboard
        @transport.request(
          method: :get,
          path: '/v1/leaderboard',
          headers: { 'Accept' => 'application/json' }
        )
      end
    end
  end
end
