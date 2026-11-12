# frozen_string_literal: true

require 'json'
require_relative '../test_helper'

class PersistentStateInventoryTest < Minitest::Test
  INVENTORY_PATH = File.expand_path('../../docs/persistent_state_inventory.json', __dir__)
  REQUIRED_FIELDS = %w[id identity type handling restrictions].freeze
  EXPECTED_HANDLING = {
    'local-marshal-save' => 'reject',
    'game-state-root' => 'rebuild',
    'global-switches' => 'serialize',
    'global-variables' => 'serialize',
    'self-switches' => 'serialize',
    'self-variables' => 'reject',
    'trainer-party-and-actors' => 'serialize',
    'system-screen-and-player' => 'serialize',
    'map-and-events' => 'rebuild',
    'erased-events' => 'serialize',
    'interpreter-execution' => 'reject',
    'temporary-state' => 'reject',
    'plugin-extension-data' => 'reject',
    'save-compatibility-metadata' => 'serialize',
    'user-data' => 'reject',
    'pathfinding-requests' => 'reject',
    'nuzlocke-state' => 'reject',
    'berry-state' => 'reject',
    'game-troop' => 'rebuild',
    'tint-time-set' => 'serialize'
  }.freeze
  REQUIRED_RESTRICTIONS = {
    'global-switches' => 'Keep explicit false values; omission is not equivalent to false.',
    'global-variables' => 'Reject values outside the supported integer domain.',
    'self-switches' => 'Use an ordered tuple [map_id, event_id, switch_id]; never stringify the key.',
    'self-variables' => 'Reject until an adapter defines reversible tuple keys and an explicit allowlist of value types.',
    'map-and-events' => 'Do not serialize live Game_Event objects.',
    'erased-events' => 'do not infer that every runtime erase is persistent.',
    'plugin-extension-data' => 'Reject unless the installed plugin supplies a versioned adapter',
    'user-data' => 'Reject arbitrary Hash values',
    'pathfinding-requests' => 'Never serialize live pathfinding requests',
    'nuzlocke-state' => 'Reject until an adapter defines its supported fields',
    'berry-state' => 'Reject until an adapter defines the supported berry keys and values',
    'game-troop' => 'Do not serialize a live battle troop',
    'tint-time-set' => 'Allow only a boolean value'
  }.freeze

  def inventory
    @inventory ||= JSON.parse(File.read(INVENTORY_PATH))
  end

  def entries
    inventory.fetch('entries')
  end

  def entry(id)
    entries.find { |candidate| candidate.fetch('id') == id }
  end

  def test_describes_every_entry_with_a_safe_handling_decision
    assert_equal 1, inventory.fetch('schema_version')
    refute_empty entries

    entries.each do |candidate|
      REQUIRED_FIELDS.each { |field| refute_empty candidate.fetch(field) }
      assert_includes %w[serialize rebuild reject], candidate.fetch('handling')
    end
  end

  def test_preserves_reversible_event_keys_and_false_switch_values
    self_switches = entry('self-switches')
    assert_equal 'serialize', self_switches.fetch('handling')
    assert_includes self_switches.fetch('restrictions'), 'Use an ordered tuple [map_id, event_id, switch_id]; never stringify the key.'

    global_switches = entry('global-switches')
    assert_equal 'serialize', global_switches.fetch('handling')
    assert_includes global_switches.fetch('restrictions'), 'Keep explicit false values; omission is not equivalent to false.'
  end

  def test_covers_all_known_persistent_groups
    EXPECTED_HANDLING.each do |id, handling|
      assert_equal handling, entry(id).fetch('handling'), id
    end
  end

  def test_preserves_the_critical_restriction_for_each_risky_group
    REQUIRED_RESTRICTIONS.each do |id, restriction|
      assert_includes entry(id).fetch('restrictions'), restriction, id
    end
  end
end
