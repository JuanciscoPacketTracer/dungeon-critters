# frozen_string_literal: true

module DungeonCritters
  module Online
    class ControlledTransport
      Response = Struct.new(:status, :headers, :body)

      attr_reader :requests

      def initialize
        @requests = []
        @responses = []
      end

      def enqueue_response(status:, headers:, body:)
        @responses << Response.new(status, headers, body)
      end

      def request(method:, path:, headers: {}, body: nil)
        @requests << {
          method: method,
          path: path,
          headers: headers,
          body: body
        }

        @responses.shift || raise(UnexpectedRequest, "#{method.to_s.upcase} #{path}")
      end

      class UnexpectedRequest < StandardError; end
    end
  end
end
