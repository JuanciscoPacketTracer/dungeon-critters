# frozen_string_literal: true

require 'tmpdir'
require 'open3'
require 'rbconfig'
require_relative '../test_helper'

SaveConfig = Struct.new(:save_header, :save_key)

module Configs
  def self.save_config
    SaveConfig.new('DUNCR', 0)
  end
end

module PFM
  class << self
    attr_accessor :game_state
  end
end

module GamePlay
  module Save
    BEFORE_SAVE_HOOKS = {}
    AFTER_SAVE_HOOKS = {}

    class << self
      attr_accessor :events, :save_path

      def clear_states
        events << :clear_states
      end

      def update_save_info
        events << :update_save_info
      end

      def encrypt(data)
        data
      end

      def save_filename
        save_path
      end

      private

      def backup_filename(filename)
        "#{filename}.bak"
      end
    end
  end
end

Scene = Struct.new(:messages) do
  def display_message_and_wait(message)
    messages << message
  end
end

def text_get(*)
  'Save failed'
end

require_relative '../../scripts/00001 LocalSave/00000 ConfirmedLocalSave'

class LocalSaveTest < Minitest::Test
  def setup
    GamePlay::Save.events = []
    GamePlay::Save::BEFORE_SAVE_HOOKS.clear
    GamePlay::Save::AFTER_SAVE_HOOKS.clear
    DungeonCritters::LocalSave.clear_confirmed_snapshots
    PFM.game_state = { player: 'Cave Critter' }
    $game_temp = Object.new
    $scene = Scene.new([])
  end

  def test_queues_a_snapshot_only_after_a_verified_local_save
    with_save_path do |path|
      GamePlay::Save::BEFORE_SAVE_HOOKS[:before] = proc { GamePlay::Save.events << :before }
      GamePlay::Save::AFTER_SAVE_HOOKS[:after] = proc { GamePlay::Save.events << :after }

      save_data = GamePlay::Save.save(path)

      assert_equal save_data, File.binread(path)
      assert_equal [:clear_states, :update_save_info, :before, :after], GamePlay::Save.events
      snapshot = DungeonCritters::LocalSave.next_confirmed_snapshot
      assert_equal path, snapshot.filename
      assert_equal save_data, snapshot.data
      assert_nil DungeonCritters::LocalSave.next_confirmed_snapshot
    end
  end

  def test_keeps_save_file_private
    with_save_path do |path|
      assert_includes GamePlay::Save.private_methods, :save_file
      assert_raises(NoMethodError) { GamePlay::Save.save_file(path, 'save data') }
    end
  end

  def test_reports_and_returns_a_failure_for_any_write_exception
    error = Exception.new('write failed')

    File.stub(:binwrite, ->(*) { raise error }) do
      result = DungeonCritters::LocalSave.write_file('save', 'save data')

      refute_predicate result, :success?
      assert_same error, result.error
    end

    assert_equal 'Save failed', $scene.messages.last
  end

  def test_logs_an_error_when_gameplay_save_is_undefined_during_loading
    script_path = File.expand_path('../../scripts/00001 LocalSave/00000 ConfirmedLocalSave.rb', __dir__)
    source = <<~RUBY
      def log_error(message)
        puts message
      end

      load #{script_path.dump}
    RUBY
    output, status = Open3.capture2(RbConfig.ruby, '-e', source)

    assert_predicate status, :success?
    assert_includes output, 'DungeonCritters::LocalSave requires GamePlay::Save to be defined before loading.'
  end

  def test_keeps_after_hooks_but_does_not_queue_a_snapshot_when_local_writing_fails
    with_save_path('missing/save') do |path|
      GamePlay::Save::BEFORE_SAVE_HOOKS[:before] = proc { GamePlay::Save.events << :before }
      GamePlay::Save::AFTER_SAVE_HOOKS[:after] = proc { GamePlay::Save.events << :after }

      save_data = GamePlay::Save.save(path)

      assert_equal [:clear_states, :update_save_info, :before, :after], GamePlay::Save.events
      assert_equal 'Save failed', $scene.messages.last
      assert_nil DungeonCritters::LocalSave.next_confirmed_snapshot
      assert_equal 'DUNCR', save_data[0, 5]
    end
  end

  def test_does_not_queue_a_snapshot_when_no_file_is_requested
    with_save_path do |path|
      save_data = GamePlay::Save.save(path, true)

      refute File.exist?(path)
      assert_equal 'DUNCR', save_data[0, 5]
      assert_nil DungeonCritters::LocalSave.next_confirmed_snapshot
    end
  end

  def test_keeps_only_the_latest_confirmed_snapshot
    with_save_path do |path|
      GamePlay::Save.save(path)
      PFM.game_state = { player: 'Forest Critter' }
      latest_data = GamePlay::Save.save(path)

      snapshot = DungeonCritters::LocalSave.next_confirmed_snapshot
      assert_equal latest_data, snapshot.data
      assert_nil DungeonCritters::LocalSave.next_confirmed_snapshot
    end
  end

  private

  def with_save_path(relative_path = 'save')
    Dir.mktmpdir do |directory|
      path = File.join(directory, relative_path)
      yield path
    end
  end
end
