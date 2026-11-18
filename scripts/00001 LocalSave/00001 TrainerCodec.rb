# frozen_string_literal: true

require 'json'

module DungeonCritters
  module Persistence
    class TrainerCodec
      SCHEMA_VERSION = 1
      ROOT_FIELDS = %w[schema_version trainer party storage critters].freeze
      TRAINER_FIELDS = %w[
        name_boy name_girl playing_girl id_boy id_girl start_time play_time badges
        region game_version current_version friend_code
      ].freeze
      CRITTER_FIELDS = %w[
        species level exp hp code form gender nature shiny loyalty ivs evs moves
        held_item ability alpha height_scalar weight_scalar
      ].freeze
      STORAGE_FIELDS = %w[current_box current_battle_box boxes battle_boxes other_party lets_go_follower].freeze
      BOX_FIELDS = %w[name theme slots].freeze
      BATTLE_BOX_FIELDS = %w[name slots].freeze

      class ValidationError < StandardError; end
      class ApplicationError < StandardError; end

      def initialize(reference_catalog:)
        @reference_catalog = reference_catalog
      end

      def encode(trainer:, party:, storage:)
        JSON.generate(export(trainer: trainer, party: party, storage: storage))
      end

      def export(trainer:, party:, storage:)
        critters = IdentityTable.new
        document = {
          'schema_version' => SCHEMA_VERSION,
          'trainer' => export_trainer(trainer),
          'party' => export_slots(collection_values(party), critters),
          'storage' => export_storage(storage, critters),
          'critters' => critters.to_h
        }
        normalize(document)
      end

      def read(serialized)
        document = JSON.parse(serialized)
        normalize(document)
      rescue JSON::ParserError => error
        raise ValidationError, "invalid JSON: #{error.message}"
      end

      def normalize(document)
        validate(document)
        deep_copy(document)
      end

      def validate(document)
        require_hash(document, 'root')
        require_exact_keys(document, ROOT_FIELDS, 'root')
        require_integer(document['schema_version'], 'schema_version')
        reject_unless(document['schema_version'] == SCHEMA_VERSION, 'unsupported schema_version')
        validate_trainer(document['trainer'])
        validate_critter_table(document['critters'])
        validate_slots(document['party'], 'party')
        validate_storage(document['storage'])
        validate_shared_reference_policy(document)
        true
      end

      def restore(serialized_or_document, trainer:, party:, storage:, factory:)
        document = serialized_or_document.is_a?(String) ? read(serialized_or_document) : normalize(serialized_or_document)
        prepared = prepare(document, factory)
        transaction = Transaction.new(trainer: trainer, party: party, storage: storage)
        transaction.apply(prepared)
        document
      rescue ValidationError
        raise
      rescue StandardError => error
        raise ApplicationError, "trainer codec application failed: #{error.message}"
      end

      private

      def prepare(document, factory)
        critters = document['critters'].each_with_object({}) do |(id, data), result|
          result[id] = factory.call(data)
        end
        {
          trainer: document['trainer'],
          party: resolve_slots(document['party'], critters),
          storage: prepare_storage(document['storage'], critters)
        }
      rescue StandardError => error
        raise ApplicationError, "trainer codec preparation failed: #{error.message}"
      end

      def prepare_storage(storage, critters)
        {
          'current_box' => storage['current_box'],
          'current_battle_box' => storage['current_battle_box'],
          'boxes' => storage['boxes'].map { |box| prepare_box(box, critters) },
          'battle_boxes' => storage['battle_boxes'].map { |box| prepare_battle_box(box, critters) },
          'other_party' => resolve_slots(storage['other_party'], critters),
          'lets_go_follower' => resolve_reference(storage['lets_go_follower'], critters)
        }
      end

      def prepare_box(box, critters)
        {'name' => box['name'], 'theme' => box['theme'], 'slots' => resolve_slots(box['slots'], critters)}
      end

      def prepare_battle_box(box, critters)
        {'name' => box['name'], 'slots' => resolve_slots(box['slots'], critters)}
      end

      def resolve_slots(slots, critters)
        slots.map { |reference| resolve_reference(reference, critters) }
      end

      def resolve_reference(reference, critters)
        return nil if reference.nil?
        critters.fetch(reference)
      end

      def export_trainer(trainer)
        TRAINER_FIELDS.to_h { |field| [field, read_value(trainer, field)] }
      end

      def export_storage(storage, critters)
        {
          'current_box' => read_value(storage, 'current_box'),
          'current_battle_box' => read_value(storage, 'current_battle_box'),
          'boxes' => Array(read_value(storage, 'boxes')).map { |box| export_box(box, critters) },
          'battle_boxes' => Array(read_value(storage, 'battle_boxes')).map { |box| export_battle_box(box, critters) },
          'other_party' => export_slots(Array(read_value(storage, 'other_party')), critters),
          'lets_go_follower' => export_reference(read_value(storage, 'lets_go_follower'), critters)
        }
      end

      def export_box(box, critters)
        {'name' => read_value(box, 'name'), 'theme' => read_value(box, 'theme'),
         'slots' => export_slots(Array(read_value(box, 'content')), critters)}
      end

      def export_battle_box(box, critters)
        {'name' => read_value(box, 'name'), 'slots' => export_slots(Array(read_value(box, 'content')), critters)}
      end

      def export_slots(slots, critters)
        slots.map { |critter| export_reference(critter, critters) }
      end

      def export_reference(critter, critters)
        return nil if critter.nil?
        critters.add(critter, export_critter(critter))
      end

      def export_critter(critter)
        {
          'species' => symbol_value(critter, :db_symbol, :species),
          'level' => read_value(critter, 'level'),
          'exp' => read_value(critter, 'exp'),
          'hp' => read_value(critter, 'hp'),
          'code' => read_value(critter, 'code'),
          'form' => read_value(critter, 'form'),
          'gender' => read_value(critter, 'gender'),
          'nature' => symbol_value(critter, :nature_db_symbol, :nature),
          'shiny' => read_value(critter, 'shiny?'),
          'loyalty' => read_value(critter, 'loyalty'),
          'ivs' => %w[hp atk dfe spd ats dfs].map { |stat| read_value(critter, "iv_#{stat}") },
          'evs' => %w[hp atk dfe spd ats dfs].map { |stat| read_value(critter, "ev_#{stat}") },
          'moves' => export_moves(critter),
          'held_item' => optional_item_symbol(critter),
          'ability' => symbol_value(critter, :ability_db_symbol, :ability),
          'alpha' => read_value(critter, 'alpha'),
          'height_scalar' => read_value(critter, 'height_scalar'),
          'weight_scalar' => read_value(critter, 'weight_scalar')
        }
      end

      def export_moves(critter)
        moves = critter.respond_to?(:skills_set) ? critter.skills_set : Array(critter.moves)
        Array(moves).map { |move| symbol_value(move, :db_symbol, :id, :move) }
      end

      def validate_trainer(trainer)
        require_hash(trainer, 'trainer')
        require_exact_keys(trainer, TRAINER_FIELDS, 'trainer')
        %w[name_boy name_girl].each { |field| require_string(trainer[field], "trainer.#{field}") }
        require_boolean(trainer['playing_girl'], 'trainer.playing_girl')
        %w[id_boy id_girl start_time play_time region game_version current_version].each do |field|
          require_integer(trainer[field], "trainer.#{field}")
        end
        require_boolean_array(trainer['badges'], 'trainer.badges')
        reject_unless(trainer['friend_code'].nil? || trainer['friend_code'].is_a?(String), 'trainer.friend_code must be a string or null')
      end

      def validate_critter_table(critters)
        require_hash(critters, 'critters')
        critters.each { |id, critter| validate_identifier(id, 'critters'); validate_critter(critter, "critters.#{id}") }
      end

      def validate_critter(critter, path)
        require_hash(critter, path)
        require_exact_keys(critter, CRITTER_FIELDS, path)
        require_string(critter['species'], "#{path}.species")
        validate_reference(:species, critter['species'], "#{path}.species")
        %w[level exp hp code form gender loyalty].each { |field| require_integer(critter[field], "#{path}.#{field}") }
        reject_unless(critter['gender'].between?(0, 2), "#{path}.gender is out of range")
        reject_unless(critter['loyalty'].between?(0, 255), "#{path}.loyalty is out of range")
        require_boolean(critter['shiny'], "#{path}.shiny")
        require_boolean(critter['alpha'], "#{path}.alpha")
        %w[height_scalar weight_scalar].each do |field|
          require_integer(critter[field], "#{path}.#{field}")
          reject_unless(critter[field].between?(0, 255), "#{path}.#{field} is out of range")
        end
        %w[ivs evs].each { |field| validate_integer_array(critter[field], 6, "#{path}.#{field}") }
        require_string(critter['nature'], "#{path}.nature")
        validate_reference(:natures, critter['nature'], "#{path}.nature")
        require_optional_reference(critter['held_item'], :items, "#{path}.held_item")
        require_string(critter['ability'], "#{path}.ability")
        validate_reference(:abilities, critter['ability'], "#{path}.ability")
        reject_unless(critter['moves'].is_a?(Array), "#{path}.moves must be an array")
        critter['moves'].each_with_index do |move, index|
          require_string(move, "#{path}.moves[#{index}]")
          validate_reference(:moves, move, "#{path}.moves[#{index}]")
        end
      end

      def validate_storage(storage)
        require_hash(storage, 'storage')
        require_exact_keys(storage, STORAGE_FIELDS, 'storage')
        %w[current_box current_battle_box].each { |field| require_integer(storage[field], "storage.#{field}") }
        validate_boxes(storage['boxes'])
        validate_battle_boxes(storage['battle_boxes'])
        reject_unless(storage['boxes'].any? && storage['current_box'].between?(0, storage['boxes'].length - 1),
                      'storage.current_box is out of range')
        reject_unless(storage['battle_boxes'].any? && storage['current_battle_box'].between?(0, storage['battle_boxes'].length - 1),
                      'storage.current_battle_box is out of range')
        validate_slots(storage['other_party'], 'storage.other_party')
        validate_reference_or_nil(storage['lets_go_follower'], 'storage.lets_go_follower')
      end

      def validate_boxes(boxes)
        reject_unless(boxes.is_a?(Array), 'storage.boxes must be an array')
        boxes.each_with_index do |box, index|
          require_hash(box, "storage.boxes[#{index}]")
          require_exact_keys(box, BOX_FIELDS, "storage.boxes[#{index}]")
          require_string(box['name'], "storage.boxes[#{index}].name")
          require_integer(box['theme'], "storage.boxes[#{index}].theme")
          validate_slots(box['slots'], "storage.boxes[#{index}].slots")
        end
      end

      def validate_battle_boxes(boxes)
        reject_unless(boxes.is_a?(Array), 'storage.battle_boxes must be an array')
        boxes.each_with_index do |box, index|
          require_hash(box, "storage.battle_boxes[#{index}]")
          require_exact_keys(box, BATTLE_BOX_FIELDS, "storage.battle_boxes[#{index}]")
          require_string(box['name'], "storage.battle_boxes[#{index}].name")
          validate_slots(box['slots'], "storage.battle_boxes[#{index}].slots")
        end
      end

      def validate_slots(slots, path)
        reject_unless(slots.is_a?(Array), "#{path} must be an array")
        slots.each_with_index { |reference, index| validate_reference_or_nil(reference, "#{path}[#{index}]") }
      end

      def validate_reference_or_nil(reference, path)
        return if reference.nil?
        require_string(reference, path)
        validate_identifier(reference, path)
      end

      def validate_shared_reference_policy(document)
        references = all_references(document)
        references.each do |reference|
          reject_unless(document['critters'].key?(reference), "unknown Critter reference: #{reference}")
        end
      end

      def all_references(document)
        storage = document['storage']
        slots = [document['party'], storage['other_party']]
        slots.concat(storage['boxes'].map { |box| box['slots'] })
        slots.concat(storage['battle_boxes'].map { |box| box['slots'] })
        slots << [storage['lets_go_follower']]
        slots.flatten.compact
      end

      def validate_identifier(value, path)
        require_string(value, path)
        reject_unless(/\Ac[0-9]+\z/.match?(value), "#{path} must be a local Critter ID")
      end

      def validate_reference(group, value, path)
        allowed = @reference_catalog.fetch(group) { raise ValidationError, "reference catalog missing #{group}" }
        reject_unless(allowed.include?(value), "unknown reference at #{path}: #{value}")
      end

      def require_optional_reference(value, group, path)
        return if value.nil?
        require_string(value, path)
        validate_reference(group, value, path)
      end

      def read_value(object, name)
        object.public_send(name)
      end

      def collection_values(collection)
        return collection.actors if collection.respond_to?(:actors)
        Array(collection)
      end

      def optional_item_symbol(critter)
        value = symbol_value(critter, :item_db_symbol, :item_holding)
        value == '__undef__' ? nil : value
      end

      def symbol_value(object, *names)
        names.each do |name|
          next unless object.respond_to?(name)
          value = object.public_send(name)
          return value.to_s
        end
        nil
      end

      def require_exact_keys(value, expected, path)
        reject_unless(value.keys.sort == expected.sort, "#{path} has unknown or missing fields")
      end

      def require_hash(value, path)
        reject_unless(value.is_a?(Hash), "#{path} must be an object")
      end

      def require_string(value, path)
        reject_unless(value.is_a?(String), "#{path} must be a string")
      end

      def require_integer(value, path)
        reject_unless(value.is_a?(Integer), "#{path} must be an integer")
      end

      def require_boolean(value, path)
        reject_unless(value == true || value == false, "#{path} must be a boolean")
      end

      def require_boolean_array(value, path)
        reject_unless(value.is_a?(Array) && value.all? { |item| item == true || item == false }, "#{path} must be an array of booleans")
      end

      def validate_integer_array(value, length, path)
        reject_unless(value.is_a?(Array) && value.length == length && value.all? { |item| item.is_a?(Integer) }, "#{path} must contain #{length} integers")
      end

      def reject_unless(condition, message)
        raise ValidationError, message unless condition
      end

      def deep_copy(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, item), copy| copy[key] = deep_copy(item) }
        when Array
          value.map { |item| deep_copy(item) }
        else
          value
        end
      end

      class IdentityTable
        def initialize
          @ids = {}
          @values = {}
        end

        def add(object, value)
          key = object.__id__
          @ids[key] ||= "c#{@ids.length + 1}"
          @values[@ids[key]] ||= value
          @ids[key]
        end

        def to_h
          @values
        end
      end

      class Transaction
        def initialize(trainer:, party:, storage:)
          @trainer = trainer
          @party = party
          @storage = storage
          @snapshot = snapshot
        end

        def apply(prepared)
          apply_trainer(prepared[:trainer])
          replace_collection(@party, prepared[:party])
          apply_storage(prepared[:storage])
        rescue StandardError => error
          begin
            rollback
          rescue StandardError => rollback_error
            raise ApplicationError, "rollback failed after #{error.message}: #{rollback_error.message}"
          end
          raise error
        end

        private

        def snapshot
          {
            trainer: TrainerSnapshot.new(@trainer),
            party: collection(@party),
            storage: StorageSnapshot.new(@storage)
          }
        end

        def apply_trainer(values)
          values.each do |field, value|
            next if field == 'playing_girl'
            @trainer.public_send("#{field}=", value)
          end
          if @trainer.respond_to?(:define_gender)
            @trainer.define_gender(values['playing_girl'])
          else
            @trainer.playing_girl = values['playing_girl']
          end
        end

        def replace_collection(target, values)
          target.respond_to?(:actors) ? target.actors.replace(values) : target.replace(values)
        end

        def apply_storage(values)
          @storage.current_box = values['current_box']
          @storage.current_battle_box = values['current_battle_box']
          apply_boxes(@storage.boxes, values['boxes'])
          apply_battle_boxes(@storage.battle_boxes, values['battle_boxes'])
          @storage.other_party.replace(values['other_party'])
          @storage.lets_go_follower = values['lets_go_follower']
        end

        def apply_boxes(targets, values)
          values.each_with_index do |value, index|
            target = targets.fetch(index)
            target.name = value['name']
            target.theme = value['theme']
            target.content.replace(value['slots'])
          end
        end

        def apply_battle_boxes(targets, values)
          values.each_with_index do |value, index|
            target = targets.fetch(index)
            target.name = value['name']
            target.content.replace(value['slots'])
          end
        end

        def rollback
          @snapshot[:trainer].restore(@trainer)
          @party.respond_to?(:actors) ? @party.actors.replace(@snapshot[:party]) : @party.replace(@snapshot[:party])
          @snapshot[:storage].restore(@storage)
        end

        def collection(target)
          target.respond_to?(:actors) ? target.actors.dup : target.dup
        end
      end

      class TrainerSnapshot
        def initialize(trainer)
          @values = TRAINER_FIELDS.each_with_object({}) { |field, result| result[field] = trainer.public_send(field) }
        end

        def restore(trainer)
          @values.each { |field, value| trainer.public_send("#{field}=", value) }
          trainer.define_gender(@values['playing_girl']) if trainer.respond_to?(:define_gender)
        end
      end

      class StorageSnapshot
        def initialize(storage)
          @current_box = storage.current_box
          @current_battle_box = storage.current_battle_box
          @boxes = storage.boxes.map { |box| [box.name, box.theme, box.content.dup] }
          @battle_boxes = storage.battle_boxes.map { |box| [box.name, box.content.dup] }
          @other_party = storage.other_party.dup
          @lets_go_follower = storage.lets_go_follower
        end

        def restore(storage)
          storage.current_box = @current_box
          storage.current_battle_box = @current_battle_box
          @boxes.each_with_index do |(name, theme, content), index|
            box = storage.boxes.fetch(index)
            box.name = name
            box.theme = theme
            box.content.replace(content)
          end
          @battle_boxes.each_with_index do |(name, content), index|
            box = storage.battle_boxes.fetch(index)
            box.name = name
            box.content.replace(content)
          end
          storage.other_party.replace(@other_party)
          storage.lets_go_follower = @lets_go_follower
        end
      end
    end
  end
end
