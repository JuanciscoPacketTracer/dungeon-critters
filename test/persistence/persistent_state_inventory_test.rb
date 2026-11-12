# frozen_string_literal: true

require 'json'
require_relative '../test_helper'

class PersistentStateInventoryTest < Minitest::Test
  INVENTORY_PATH = File.expand_path('../../docs/persistent_state_inventory.json', __dir__)
  REQUIRED_FIELDS = %w[id identity type handling restrictions].freeze

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

  def test_rebuilds_map_definitions_and_rejects_untrusted_runtime_objects
    assert_equal 'rebuild', entry('map-and-events').fetch('handling')
    assert_equal 'reject', entry('interpreter-execution').fetch('handling')
    assert_equal 'reject', entry('plugin-extension-data').fetch('handling')
    assert_equal 'reject', entry('local-marshal-save').fetch('handling')
  end
end
