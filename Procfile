web: RACK_ENV=production bundle exec puma -b tcp://0.0.0.0:$PORT server/config.ru
worker: RACK_ENV=production bundle exec ruby server/bin/outbox_worker.rb
