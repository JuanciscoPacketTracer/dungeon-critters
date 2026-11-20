# frozen_string_literal: true

require 'json'
require 'roda'
require_relative 'lib/dungeon_critters_server'
require_relative 'lib/save_upload'

delegate = DungeonCritters::Server::App.new
save_store = DungeonCritters::Server::PostgresSaveStore.new
reference_catalog = JSON.parse(ENV.fetch('SAVE_REFERENCE_CATALOG_JSON', '{}')).each_with_object({}) do |(key, values), catalog|
  catalog[key.to_sym] = values
end
save_upload = DungeonCritters::Server::SaveUploadApp.new(
  service: DungeonCritters::Server::SaveUploadService.new(
    store: save_store,
    payload_validator: DungeonCritters::Server::TrainerCodecValidator.new(
      reference_catalog: reference_catalog
    )
  ),
  authenticator: DungeonCritters::Server::SessionAuthenticator.new(
    session_service: delegate.session_service
  )
)

roda_app = Class.new(Roda) do
  route do |request|
    response_tuple = if request.env['PATH_INFO'].to_s.match?(%r{\A/v1/saves/[^/]+/versions\z})
                       save_upload.call(request.env)
                     else
                       delegate.call(request.env)
                     end
    status, headers, body = response_tuple
    response.status = status
    headers.each { |name, value| response[name] = value }
    body.join
  end
end

run roda_app
