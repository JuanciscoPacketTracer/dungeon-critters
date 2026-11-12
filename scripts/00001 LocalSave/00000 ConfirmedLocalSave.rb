# frozen_string_literal: true

module DungeonCritters
  module LocalSave
    Snapshot = Struct.new(:filename, :data, keyword_init: true)
    WriteResult = Struct.new(:success?, :error, keyword_init: true)

    class << self
      def write_file(filename, save_data)
        backup_filename = GamePlay::Save.send(:backup_filename, filename)
        File.delete(backup_filename) if File.exist?(backup_filename)
        File.rename(filename, backup_filename) if File.exist?(filename)
        File.binwrite(filename, save_data)

        return WriteResult.new(success?: true) if File.binread(filename) == save_data

        $scene.display_message_and_wait(text_get(26, 19))
        File.rename(backup_filename, filename) if File.exist?(backup_filename)
        WriteResult.new(success?: false)
      rescue Exception => error
        $scene.display_message_and_wait(text_get(26, 19))
        WriteResult.new(success?: false, error: error)
      end

      def record_confirmed_snapshot(filename, save_data)
        @confirmed_snapshot = Snapshot.new(filename: filename.dup.freeze, data: save_data.dup.freeze).freeze
      end

      def next_confirmed_snapshot
        snapshot = @confirmed_snapshot
        @confirmed_snapshot = nil
        snapshot
      end

      def clear_confirmed_snapshots
        @confirmed_snapshot = nil
      end
    end

    module GamePlaySavePatch
      def save(filename = nil, no_file = false)
        return 'NONE' unless $game_temp

        clear_states
        update_save_info
        GamePlay::Save::BEFORE_SAVE_HOOKS.each_value(&:call)
        save_data = Configs.save_config.save_header.dup.force_encoding(Encoding::ASCII_8BIT)
        save_data << encrypt(Marshal.dump(PFM.game_state))
        filename ||= GamePlay::Save.save_filename
        saved = no_file || save_file(filename, save_data)
        GamePlay::Save::AFTER_SAVE_HOOKS.each_value(&:call)
        DungeonCritters::LocalSave.record_confirmed_snapshot(filename, save_data) if saved && !no_file
        save_data
      end

      def save_file(filename, save_data)
        result = DungeonCritters::LocalSave.write_file(filename, save_data)
        result.success?
      end
      private :save_file
    end
  end
end

if defined?(GamePlay::Save)
  GamePlay::Save.singleton_class.prepend(DungeonCritters::LocalSave::GamePlaySavePatch)
else
  log_error('DungeonCritters::LocalSave requires GamePlay::Save to be defined before loading.')
end
