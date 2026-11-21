#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'dungeon_critters_server'

include DungeonCritters

environment = ENV.fetch('RACK_ENV', 'development')
Server::OUTBOX_REQUIRED_ENV.each { |name| Server.require_env!(name) }
database_url = Server.require_env!('DATABASE_URL')

verification_tokens = Server::VerificationTokenCodec.from_env(environment: environment)
store = Server::PostgresStore.new(database_url)
mailer = Server::ResendMailer.new(environment: environment)
dispatcher = Server::OutboxDispatcher.new(
  store: store,
  mailer: mailer,
  verification_tokens: verification_tokens
)
worker = Server::OutboxWorker.new(
  store: store,
  dispatcher: dispatcher,
  poll_interval: ENV.fetch('OUTBOX_POLL_INTERVAL', Server::OutboxWorker::DEFAULT_POLL_INTERVAL),
  backoff_base: ENV.fetch('OUTBOX_BACKOFF_BASE', Server::OutboxWorker::DEFAULT_BACKOFF_BASE),
  backoff_max: ENV.fetch('OUTBOX_BACKOFF_MAX', Server::OutboxWorker::DEFAULT_BACKOFF_MAX),
  max_attempts: ENV.fetch('OUTBOX_MAX_ATTEMPTS', Server::OutboxWorker::DEFAULT_MAX_ATTEMPTS)
)

stopping = false
%w[INT TERM].each { |signal| Signal.trap(signal) { stopping = true } }
warn("outbox worker started environment=#{environment}")
worker.run(stop: -> { stopping })
warn('outbox worker stopped')
