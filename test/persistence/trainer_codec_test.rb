# frozen_string_literal: true

require 'json'
require 'set'
require_relative '../test_helper'
require_relative '../../scripts/00001 LocalSave/00001 TrainerCodec'

class TrainerCodecTest < Minitest::Test
  CATALOG = {
    species: Set.new(%w[bunli]),
    natures: Set.new(%w[brave]),
    moves: Set.new(%w[tackle]),
    items: Set.new(%w[poke_ball]),
    abilities: Set.new(%w[run_away])
  }.freeze

  class Critter
    attr_accessor :level, :exp, :hp, :code, :form, :gender, :loyalty,
                  :iv_hp, :iv_atk, :iv_dfe, :iv_spd, :iv_ats, :iv_dfs,
                  :ev_hp, :ev_atk, :ev_dfe, :ev_spd, :ev_ats, :ev_dfs,
                  :skills_set, :alpha, :height_scalar, :weight_scalar
    attr_reader :db_symbol, :nature_db_symbol, :item_db_symbol, :ability_db_symbol

    def initialize(species: :bunli, code: 99)
      @db_symbol = species
      @nature_db_symbol = :brave
      @item_db_symbol = :poke_ball
      @ability_db_symbol = :run_away
      @level = 5
      @exp = 125
      @hp = 20
      @code = code
      @form = 0
      @gender = 1
      @loyalty = 40
      @iv_hp, @iv_atk, @iv_dfe, @iv_spd, @iv_ats, @iv_dfs = 1, 2, 3, 4, 5, 6
      @ev_hp, @ev_atk, @ev_dfe, @ev_spd, @ev_ats, @ev_dfs = 0, 1, 2, 3, 4, 5
      @skills_set = [Struct.new(:db_symbol).new(:tackle)]
      @alpha = true
      @height_scalar = 17
      @weight_scalar = 231
    end

    def shiny?
      false
    end
  end

  class Box
    attr_accessor :name, :theme
    attr_reader :content

    def initialize(name, theme, content)
      @name = name
      @theme = theme
      @content = content
    end
  end

  class BattleBox
    attr_accessor :name
    attr_reader :content

    def initialize(name, content)
      @name = name
      @content = content
    end
  end

  class Storage
    attr_accessor :current_battle_box, :boxes, :battle_boxes,
                  :other_party, :lets_go_follower
    attr_writer :fail_next_current_box

    def initialize(shared, other)
      @current_box = 0
      @current_battle_box = 0
      @boxes = [Box.new('Box 1', 1, [nil, shared, nil])]
      @battle_boxes = [BattleBox.new('#1', [shared, nil])]
      @other_party = [other]
      @lets_go_follower = shared
    end

    attr_reader :current_box

    def current_box=(value)
      if @fail_next_current_box
        @fail_next_current_box = false
        raise 'synthetic commit failure'
      end
      @current_box = value
    end
  end

  class Trainer
    attr_accessor :name_boy, :name_girl, :playing_girl, :id_boy, :id_girl,
                  :start_time, :play_time, :badges, :region, :game_version,
                  :current_version, :friend_code
    attr_reader :gender_state

    def initialize
      @name_boy = 'Ash'
      @name_girl = 'Misty'
      @playing_girl = false
      @id_boy = 10
      @id_girl = 20
      @start_time = 100
      @play_time = 3600
      @badges = [true, false]
      @region = 0
      @game_version = 1
      @current_version = 1
      @friend_code = nil
      @gender_state = {switch: false, player_id: 10, actor_name: 'Ash'}
    end

    def define_gender(value)
      @playing_girl = value
      @gender_state[:switch] = value
      @gender_state[:player_id] = value ? @id_girl : @id_boy
      @gender_state[:actor_name] = value ? @name_girl : @name_boy
    end
  end

  def setup
    @codec = DungeonCritters::Persistence::TrainerCodec.new(reference_catalog: CATALOG)
    @trainer = Trainer.new
    @shared = Critter.new(code: 99)
    @other = Critter.new(code: 100)
    @storage = Storage.new(@shared, @other)
  end

  def test_round_trip_preserves_storage_slots_shared_references_and_size_values
    document = @codec.export(trainer: @trainer, party: [@shared], storage: @storage)

    assert_equal 1, document['schema_version']
    assert_equal true, document['critters']['c1']['alpha']
    assert_equal 17, document['critters']['c1']['height_scalar']
    assert_equal 231, document['critters']['c1']['weight_scalar']
    assert_equal [nil, 'c1', nil], document['storage']['boxes'][0]['slots']
    assert_equal ['c1', nil], document['storage']['battle_boxes'][0]['slots']
    assert_equal 'c1', document['storage']['lets_go_follower']
    assert_equal document, @codec.read(@codec.encode(trainer: @trainer, party: [@shared], storage: @storage))
  end

  def test_restore_reuses_one_object_for_every_shared_reference_and_applies_gender_effects
    document = @codec.export(trainer: @trainer, party: [@shared], storage: @storage)
    document['trainer']['playing_girl'] = true
    target_trainer = Trainer.new
    target_party = []
    target_storage = Storage.new(Critter.new(code: 200), Critter.new(code: 201))

    @codec.restore(document, trainer: target_trainer, party: target_party, storage: target_storage, factory: ->(data) { data })

    restored = target_party.fetch(0)
    assert_same restored, target_storage.boxes[0].content[1]
    assert_same restored, target_storage.battle_boxes[0].content[0]
    assert_same restored, target_storage.lets_go_follower
    assert_equal true, target_trainer.playing_girl
    assert_equal true, target_trainer.gender_state[:switch]
    assert_equal 20, target_trainer.gender_state[:player_id]
    assert_equal 'Misty', target_trainer.gender_state[:actor_name]
  end

  def test_rejects_missing_or_unknown_references_without_mutating_targets
    document = @codec.export(trainer: @trainer, party: [@shared], storage: @storage)
    document['storage']['boxes'][0]['slots'][1] = 'c999'
    original_party = [:original]
    original_box = @storage.boxes[0].content.dup

    assert_raises(DungeonCritters::Persistence::TrainerCodec::ValidationError) do
      @codec.restore(document, trainer: @trainer, party: original_party, storage: @storage, factory: ->(data) { data })
    end
    assert_equal [:original], original_party
    assert_equal original_box, @storage.boxes[0].content
  end

  def test_rolls_back_trainer_party_and_storage_when_commit_fails
    document = @codec.export(trainer: @trainer, party: [@shared], storage: @storage)
    target_trainer = Trainer.new
    target_party = [:old_party]
    target_storage = Storage.new(Critter.new(code: 200), Critter.new(code: 201))
    target_storage.fail_next_current_box = true if target_storage.respond_to?(:fail_next_current_box=)

    error = assert_raises(DungeonCritters::Persistence::TrainerCodec::ApplicationError) do
      @codec.restore(document, trainer: target_trainer, party: target_party, storage: target_storage, factory: ->(data) { data })
    end

    assert_match(/application failed/, error.message)
    assert_equal [:old_party], target_party
    assert_equal false, target_trainer.playing_girl
    assert_equal 0, target_storage.current_box
    assert_equal 'Box 1', target_storage.boxes[0].name
  end

  def test_factory_failure_does_not_mutate_any_runtime_state
    document = @codec.export(trainer: @trainer, party: [@shared], storage: @storage)
    target_trainer = Trainer.new
    target_party = [:old_party]
    target_storage = Storage.new(Critter.new(code: 200), Critter.new(code: 201))
    original_gender = target_trainer.gender_state.dup
    original_box = target_storage.boxes[0].content.dup
    original_battle_box = target_storage.battle_boxes[0].content.dup
    original_other_party = target_storage.other_party.dup
    original_follower = target_storage.lets_go_follower
    original_battle_cursor = target_storage.current_battle_box

    assert_raises(DungeonCritters::Persistence::TrainerCodec::ApplicationError) do
      @codec.restore(
        document,
        trainer: target_trainer,
        party: target_party,
        storage: target_storage,
        factory: ->(_data) { raise 'synthetic factory failure' }
      )
    end

    assert_equal false, target_trainer.playing_girl
    assert_equal original_gender, target_trainer.gender_state
    assert_equal [:old_party], target_party
    assert_equal original_box, target_storage.boxes[0].content
    assert_equal original_battle_box, target_storage.battle_boxes[0].content
    assert_equal original_other_party, target_storage.other_party
    assert_same original_follower, target_storage.lets_go_follower
    assert_equal 0, target_storage.current_box
    assert_equal original_battle_cursor, target_storage.current_battle_box
  end

  def test_rejects_closed_schema_and_invalid_json
    document = @codec.export(trainer: @trainer, party: [], storage: @storage)
    document['storage']['extra'] = true
    assert_raises(DungeonCritters::Persistence::TrainerCodec::ValidationError) { @codec.normalize(document) }
    document = @codec.export(trainer: @trainer, party: [], storage: @storage)
    document['schema_version'] = 2
    assert_raises(DungeonCritters::Persistence::TrainerCodec::ValidationError) { @codec.normalize(document) }
    assert_raises(DungeonCritters::Persistence::TrainerCodec::ValidationError) { @codec.read('{') }
  end
end
