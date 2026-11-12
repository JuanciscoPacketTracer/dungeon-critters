# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../support/controlled_transport'
require_relative '../support/versioned_api_client'

class ControlledTransportTest < Minitest::Test
  def test_returns_the_queued_response_for_a_versioned_request
    transport = DungeonCritters::Online::ControlledTransport.new
    transport.enqueue_response(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: '{"data":[]}'
    )

    response = transport.request(
      method: :get,
      path: '/v1/leaderboard',
      headers: { 'Accept' => 'application/json' }
    )

    assert_equal 200, response.status
    assert_equal({ 'Content-Type' => 'application/json' }, response.headers)
    assert_equal '{"data":[]}', response.body
    assert_equal(
      [
        {
          method: :get,
          path: '/v1/leaderboard',
          headers: { 'Accept' => 'application/json' },
          body: nil
        }
      ],
      transport.requests
    )
  end

  def test_reports_the_method_and_path_for_an_unexpected_request
    error = assert_raises(DungeonCritters::Online::ControlledTransport::UnexpectedRequest) do
      DungeonCritters::Online::ControlledTransport.new.request(
        method: :post,
        path: '/v1/saves/1/versions'
      )
    end

    assert_equal 'POST /v1/saves/1/versions', error.message
  end

  def test_requests_the_public_leaderboard_contract
    transport = DungeonCritters::Online::ControlledTransport.new
    transport.enqueue_response(status: 200, headers: {}, body: '{"data":[]}')

    response = DungeonCritters::Online::VersionedApiClient.new(transport).leaderboard

    assert_equal 200, response.status
    assert_equal(
      {
        method: :get,
        path: '/v1/leaderboard',
        headers: { 'Accept' => 'application/json' },
        body: nil
      },
      transport.requests.first
    )
  end
end
