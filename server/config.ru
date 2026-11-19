# frozen_string_literal: true

require 'roda'
require_relative 'lib/dungeon_critters_server'

delegate = DungeonCritters::Server::App.new

roda_app = Class.new(Roda) do
  route do |request|
    status, headers, body = delegate.call(request.env)
    response.status = status
    headers.each { |name, value| response[name] = value }
    body.join
  end
end

run roda_app
