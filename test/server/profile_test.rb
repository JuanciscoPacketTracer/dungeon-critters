# frozen_string_literal: true

require 'minitest/autorun'
require 'timeout'
require_relative '../../server/lib/dungeon_critters_server'

class ProfileTest < Minitest::Test
  def setup
    @store = DungeonCritters::Server::InMemoryStore.new
    @now = Time.utc(2026, 1, 1)
    @service = DungeonCritters::Server::ProfileService.new(
      store: @store,
      clock: -> { @now }
    )
  end

  def test_alias_is_explicit_and_profile_contains_no_private_identity
    profile = @service.set_alias(user_id: 'account-a', public_alias: 'Sky_Runner')

    assert_equal 'sky_runner', profile['alias']
    refute_includes profile.keys, 'email'
    refute_includes profile.keys, 'trainer_name'
    refute_includes profile.keys, 'user_id'
  end

  def test_alias_uniqueness_is_case_insensitive
    @service.set_alias(user_id: 'account-a', public_alias: 'Champion')

    assert_raises(DungeonCritters::Server::ConflictError) do
      @service.set_alias(user_id: 'account-b', public_alias: 'champion')
    end
  end

  def test_alias_change_is_a_no_op_for_the_current_normalized_alias
    @service.set_alias(user_id: 'account-a', public_alias: 'Champion')
    @now += 1

    profile = @service.set_alias(user_id: 'account-a', public_alias: ' champion ')

    assert_equal({ 'alias' => 'champion' }, profile)
  end

  def test_alias_format_and_reserved_names_are_rejected
    %w[ab invalid\ alias admin].each do |value|
      assert_raises(DungeonCritters::Server::ValidationError) do
        @service.set_alias(user_id: 'account-a', public_alias: value)
      end
    end
  end

  def test_alias_cannot_change_before_thirty_days
    @service.set_alias(user_id: 'account-a', public_alias: 'FirstAlias')
    @now += (30 * 24 * 60 * 60) - 1

    assert_raises(DungeonCritters::Server::ConflictError) do
      @service.set_alias(user_id: 'account-a', public_alias: 'SecondAlias')
    end
  end

  def test_released_alias_remains_reserved_for_ninety_days
    @service.set_alias(user_id: 'account-a', public_alias: 'FirstAlias')
    @now += 30 * 24 * 60 * 60
    @service.set_alias(user_id: 'account-a', public_alias: 'SecondAlias')

    assert_raises(DungeonCritters::Server::ConflictError) do
      @service.set_alias(user_id: 'account-b', public_alias: 'firstalias')
    end
  end

  def test_expired_reservation_is_removed_when_alias_is_reused
    @service.set_alias(user_id: 'account-a', public_alias: 'FirstAlias')
    @now += 30 * 24 * 60 * 60
    @service.set_alias(user_id: 'account-a', public_alias: 'SecondAlias')
    @now += 90 * 24 * 60 * 60

    @service.set_alias(user_id: 'account-b', public_alias: 'firstalias')

    assert_nil @store.alias_reservations['firstalias']
    assert_equal 'firstalias', @store.profiles['account-b'].public_alias
  end

  def test_releasing_a_reused_alias_refreshes_its_reservation_date
    @service.set_alias(user_id: 'account-a', public_alias: 'FirstAlias')
    @now += 30 * 24 * 60 * 60
    @service.set_alias(user_id: 'account-a', public_alias: 'SecondAlias')
    @now += 90 * 24 * 60 * 60
    @service.set_alias(user_id: 'account-b', public_alias: 'firstalias')
    @now += 30 * 24 * 60 * 60
    @service.set_alias(user_id: 'account-b', public_alias: 'ThirdAlias')

    assert_equal @now, @store.alias_reservations['firstalias'].released_at
  end

  def test_concurrent_alias_claim_has_one_winner
    ready = Queue.new
    start = Queue.new
    results = 2.times.map do |index|
      Thread.new do
        ready << true
        start.pop
        @service.set_alias(user_id: "account-#{index}", public_alias: 'Concurrent')
        :claimed
      rescue DungeonCritters::Server::ConflictError
        :conflict
      end
    end

    2.times { ready.pop }
    2.times { start << true }

    assert_equal %i[claimed conflict], results.map(&:value).sort
    assert_equal 1, @store.profiles.values.count { |profile| profile.alias_normalized == 'concurrent' }
  end

  def test_postgres_read_does_not_overlap_a_transaction
    store = DungeonCritters::Server::PostgresStore.allocate
    store.instance_variable_set(:@mutex, Mutex.new)
    store.instance_variable_set(:@connection, EmptyPostgresConnection.new)
    store.instance_variable_set(:@users, {})
    store.instance_variable_set(:@sessions, {})
    store.instance_variable_set(:@verifications, {})
    store.instance_variable_set(:@outbox, {})
    store.instance_variable_set(:@profiles, {})
    store.instance_variable_set(:@alias_reservations, {})

    read_entered = Queue.new
    release_read = Queue.new
    transaction_entered = Queue.new

    reader = Thread.new do
      store.read do
        read_entered << true
        release_read.pop
      end
    end
    read_entered.pop

    writer = Thread.new do
      store.transaction do
        transaction_entered << true
      end
    end

    assert_raises(Timeout::Error) do
      Timeout.timeout(0.1) { transaction_entered.pop }
    end
  ensure
    release_read << true if release_read
    reader&.join
    writer&.join
  end

  def test_postgres_persist_deletes_removed_alias_reservations
    connection = RecordingPostgresConnection.new
    store = DungeonCritters::Server::PostgresStore.allocate
    store.instance_variable_set(:@connection, connection)
    store.instance_variable_set(:@users, {})
    store.instance_variable_set(:@sessions, {})
    store.instance_variable_set(:@verifications, {})
    store.instance_variable_set(:@outbox, {})
    store.instance_variable_set(:@profiles, {})
    store.instance_variable_set(:@alias_reservations, {})
    store.instance_variable_set(:@loaded_alias_reservation_keys, ['expired'])

    store.send(:persist)

    delete_call = connection.calls.find { |sql, _params| sql.start_with?('DELETE FROM public_alias_reservations') }
    refute_nil delete_call
    assert_equal ['expired'], delete_call.last
  end

  class EmptyPostgresConnection
    def transaction
      yield
    end

    def exec(*)
      []
    end

    def exec_params(*)
      []
    end
  end

  class RecordingPostgresConnection
    attr_reader :calls

    def initialize
      @calls = []
    end

    def exec_params(sql, params)
      @calls << [sql, params]
      []
    end
  end
end
