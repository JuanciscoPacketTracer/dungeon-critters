module DMC
  module SummaryRevamp
    MODIFIER_FROM_SCORE = {
      4 => 4.0,
      3 => 3.0,
      2 => 2.0,
      1 => 2.0,
      0 => 1.0,
      -1 => 0.5,
      -2 => 0.5,
      -3 => 0.33
    }.freeze

    module_function

    def pokemon_types(pokemon)
      [pokemon.type1, pokemon.type2, pokemon.respond_to?(:type3) ? pokemon.type3 : 0]
    end

    def single_type_multiplier(attack_type_id, defensive_type_id)
      return 1.0 if defensive_type_id.to_i <= 0
      attack_type = data_type(attack_type_id)
      defensive_type = data_type(defensive_type_id)
      return attack_type.hit(defensive_type.db_symbol)
    end

    def type_multiplier(attack_type_id, pokemon)
      defender_types = pokemon_types(pokemon)

      if DMC::TypeRework::MAINTYPE
        score = 0
        defender_types.each_with_index do |def_type, index|
          next if def_type.to_i <= 0

          factor = single_type_multiplier(attack_type_id, def_type)
          return 0.0 if factor == 0

          weight = index == 0 ? 2 : 1
          score += weight if factor > 1
          score -= weight if factor < 1
        end
        return MODIFIER_FROM_SCORE[score] || 0.25
      end

      multiplier = 1.0
      defender_types.each do |def_type|
        next if def_type.to_i <= 0
        multiplier *= single_type_multiplier(attack_type_id, def_type)
      end
      return multiplier
    end

    def matchup_entries(pokemon)
      weak = []
      resist = []
      immune = []

      each_data_type do |attack_type|
        multiplier = type_multiplier(attack_type.id, pokemon)
        next if multiplier == 1.0

        row = { type_id: attack_type.id, multiplier: multiplier }
        if multiplier == 0.0
          immune << row
        elsif multiplier > 1.0
          weak << row
        else
          resist << row
        end
      end

      weak.sort_by! { |row| [-row[:multiplier], data_type(row[:type_id]).name] }
      resist.sort_by! { |row| [row[:multiplier], data_type(row[:type_id]).name] }
      immune.sort_by! { |row| data_type(row[:type_id]).name }

      entries = []
      weak.each { |row| entries << row.merge(group: :weakness) }
      resist.each { |row| entries << row.merge(group: :resistance) }
      immune.each { |row| entries << row.merge(group: :immunity) }
      return entries
    end

    def grouped_matchup_entries(pokemon)
      grouped = { weakness: [], resistance: [], immunity: [] }
      matchup_entries(pokemon).each do |entry|
        grouped[entry[:group]] << entry
      end
      return grouped
    end
  end
end

module UI
  MatchupTypeData = Struct.new(:type)

  class Summary_Abilities < SpriteStack
    VISIBLE_ROWS = 3

    attr_reader :index

    def initialize(viewport)
      super(viewport, 0, 0, default_cache: :interface)
      @entries = []
      @index = 0
      @offset = 0
      init_sprite
    end

    def data=(pokemon)
      @data = pokemon
      abilities = pokemon.get_data.abilities.uniq
      @entries = abilities.map { |ability_id| data_ability(ability_id) }
      self.index = 0
      refresh
    end

    def move_index(delta)
      return if @entries.empty?
      self.index = @index + delta
    end

    def visible=(value)
      super
      @header.visible = value
      @rows.each { |row| row.visible = value }
      @description_lines.each { |line| line.visible = value }
      @empty_text.visible = value && @entries.empty?
    end

    def index=(value)
      if @entries.empty?
        @index = 0
        @offset = 0
        return
      end

      @index = value.to_i.clamp(0, @entries.size - 1)
      @offset = [[@index - 1, 0].max, [@entries.size - VISIBLE_ROWS, 0].max].min
      refresh
    end

    private

    def init_sprite
      push(0, 0, 'summary/stats')
      @header = add_text(113, 20, 120, 16, "#{text_get(33, 142)}: ", color: 0)
      @rows = Array.new(VISIBLE_ROWS) do |row_index|
        y = 51 + row_index * 18
        text = add_text(113, y, 292, 16, '', color: 0)
        text
      end

      @empty_text = add_text(13, 50, 180, 16, text_get(22, 108), color: 2)

      @description_lines = Array.new(5) do |line_index|
        add_text(13, 138 + line_index * 16, 294, 16, '', color: 0)
      end
    end

    def refresh
      refresh_rows
      refresh_description
    end

    def refresh_rows
      @rows.each_with_index do |text, line_index|
        ability = @entries[@offset + line_index]
        if ability
          text.visible = true
          text.text = "#{@offset + line_index == @index ? '>' : ' '} #{ability.name}"
          text.load_color(@offset + line_index == @index ? 1 : 0)
        else
          text.visible = false
        end
      end
      @empty_text.visible = @entries.empty?
    end

    def refresh_description
      selected = @entries[@index]
      wrapped_lines = wrap_text(selected&.descr.to_s, 42, 5)
      @description_lines.each_with_index do |line, index|
        line.text = wrapped_lines[index] || ''
      end
    end

    def wrap_text(text, line_length, max_lines)
      words = text.split(/\s+/)
      return [] if words.empty?

      lines = []
      current = ''
      words.each do |word|
        candidate = current.empty? ? word : "#{current} #{word}"
        if candidate.length > line_length
          lines << current unless current.empty?
          current = word
          break if lines.size >= max_lines
        else
          current = candidate
        end
      end
      lines << current if !current.empty? && lines.size < max_lines
      return lines.first(max_lines)
    end
  end

  class Summary_TypeMatchups < SpriteStack
    VISIBLE_ROWS = 4
    GROUPS = %i[weakness resistance immunity].freeze

    attr_reader :index

    def initialize(viewport)
      super(viewport, 0, 0, default_cache: :interface)
      @entries = []
      @group_indices = {}
      @index = 0
      @active_group_index = 0
      @selecting = false
      init_sprite
    end

    def data=(pokemon)
      @data = pokemon
      @grouped_entries = DMC::SummaryRevamp.grouped_matchup_entries(pokemon)
      @entries = @grouped_entries.values.flatten
      @group_indices = GROUPS.each_with_object({}) { |group, hash| hash[group] = 0 }
      @active_group_index = 0
      @selecting = false
      self.index = 0
      refresh
    end

    def move_index(delta)
      return if @entries.empty?
      return unless @selecting

      entries = current_entries
      return if entries.empty?

      @group_indices[active_group] = (@group_indices[active_group] + delta).clamp(0, entries.size - 1)
      @index = @group_indices[active_group]
      refresh
    end

    def move_group(delta)
      return if @entries.empty?
      return unless @selecting

      @active_group_index = (@active_group_index + delta) % GROUPS.size
      @index = @group_indices[active_group]
      refresh
    end

    def selecting=(value)
      @selecting = value
      @index = @group_indices[active_group]
      refresh
    end

    def visible=(value)
      super
      @sections.each_value do |section|
        section[:rows].each { |row| row[:icon].visible = row[:text].visible = value }
        section[:header].visible = value
        section[:count].visible = value
      end
      @empty_text.visible = value && @entries.empty?
    end

    def index=(value)
      if @entries.empty?
        @index = 0
        return
      end

      entries = current_entries
      return if entries.empty?

      @group_indices[active_group] = value.to_i.clamp(0, entries.size - 1)
      @index = @group_indices[active_group]
      refresh
    end

    private

    def init_sprite
      push(0, 0, 'summary/moves')
      @sections = {
        weakness: create_section('Weaknesses', 13, 53, 124),
        resistance: create_section('Resistances', 133, 53, 124),
        immunity: create_section('Immunities', 233, 53, 124)
      }

      @empty_text = add_text(155, 154, 250, 16, text_get(22, 108), color: 2)
    end

    def refresh
      refresh_rows
      refresh_summary
    end

    def refresh_rows
      @sections.each do |group, section|
        entries = @grouped_entries[group] || []
        selected_index = @group_indices[group] || 0
        offset = [[selected_index - 1, 0].max, [entries.size - VISIBLE_ROWS, 0].max].min
        section[:header].load_color(group == active_group && @selecting ? 1 : 10)
        section[:rows].each_with_index do |row, line_index|
          entry = entries[offset + line_index]
          selected = @selecting && group == active_group && (offset + line_index) == selected_index
          if entry
            row[:icon].visible = true
            row[:icon].data = MatchupTypeData.new(entry[:type_id])
            row[:text].visible = true
            row[:text].text = "#{selected ? '>' : ' '} #{type_name(entry[:type_id])} x#{format_multiplier(entry[:multiplier])}"
            row[:text].load_color(selected ? 1 : 0)
          else
            row[:icon].visible = false
            row[:text].visible = false
          end
        end
      end
      @empty_text.visible = @entries.empty?
    end

    def refresh_summary
      weak_count = @entries.count { |entry| entry[:group] == :weakness }
      resist_count = @entries.count { |entry| entry[:group] == :resistance }
      immune_count = @entries.count { |entry| entry[:group] == :immunity }
      @sections[:weakness][:count].text = weak_count.to_s
      @sections[:resistance][:count].text = resist_count.to_s
      @sections[:immunity][:count].text = immune_count.to_s
    end

    def create_section(title, x, y, width)
      header = add_text(x, y, 72, 16, title, color: 10)
      count = add_text(x + 74, y, 24, 16, '0', color: 1)
      rows = Array.new(VISIBLE_ROWS) do |row_index|
        row_y = y + 18 + row_index * 18
        icon = add_sprite(x, row_y + 1, nil, type: TypeSprite)
        text = add_text(x + 33, row_y, width - 33, 16, '', color: 0)
        { icon: icon, text: text }
      end
      return { header: header, count: count, rows: rows, start_index: 0 }
    end

    def format_multiplier(value)
      return value.to_i.to_s if value == value.to_i
      return '0.5' if (value - 0.5).abs < 0.001
      return '0.33' if (value - 0.33).abs < 0.01
      return '0.25' if (value - 0.25).abs < 0.001
      return value.round(2).to_s
    end

    def type_name(type_id)
      data_type(type_id).name
    end

    def current_entries
      @grouped_entries[active_group] || []
    end

    def active_group
      GROUPS[@active_group_index]
    end
  end

  class Summary_Stat
    def init_ability
      return
    end
  end
end

module Battle
  class Visual
    module DMCAbilityMessageQueue
      def show_ability(target, no_go_out = false)
        wait_for_animation
        super
      end
    end

    prepend DMCAbilityMessageQueue
  end

  module VisualMock
    def show_ability(_target, _no_go_out = false)
      return
    end
  end
end

module GamePlay
  class Summary
    def initialize(pokemon, mode = :view, party = [pokemon], extend_data = nil)
      super()
      @pokemon = pokemon
      @mode = mode
      @party = party
      @index = mode == :skill ? 3 : 0
      @party_index = party.index(pokemon).to_i
      @skill_selected = -1
      @skill_index = -1
      @selecting_move = false
      @selecting_type_list = false
      @extend_data = extend_data
    end

    def create_uis
      @uis = [
        UI::Summary_Memo.new(@viewport),
        UI::Summary_Stat.new(@viewport),
        UI::Summary_Abilities.new(@viewport),
        UI::Summary_Skills.new(@viewport),
        UI::Summary_TypeMatchups.new(@viewport),
        UI::Summary_Contest.new(@viewport)
      ]
    end

    def last_state
      last_index = 5
      last_index -= 1 while last_index > 0 && !ui_available?(@uis[last_index])
      return last_index
    end

    def update_ctrl_state
      @base_ui.mode = ctrl_id_state
      @uis[5].show_page_version(@selecting_move ? :moves : :stats) if @index == 5
    end

    def update_ui_visibility
      @uis.each_with_index { |ui, index| ui.visible = index == @index }
      @top.compact = (@index == 4) if @top.respond_to?(:compact=)
      update_ctrl_state
    end

    def ctrl_id_state
      case @index
      when 0
        return 0 unless @pokemon.is_a?(PFM::PokemonBattler)
        return 7
      when 1, 2
        return 1
      when 4
        return 3 if @selecting_type_list
        return 1
      when 3
        return 5 if @mode == :skill
        return 4 if @skill_index >= 0
        return 3 if @selecting_move
        return 2 unless @pokemon.is_a?(PFM::PokemonBattler)
        return 8
      when 5
        return 5 if @mode == :skill
        return 4 if @skill_index >= 0
        return 3 if @selecting_move
        return 6
      end
    end

    def update_inputs_view
      case @index
      when 0, 1
        update_inputs_basic
      when 2
        update_inputs_list_ui
      when 4
        update_inputs_type_matchups_ui
      when 3, 5
        update_inputs_skill_ui
      end
      return true
    end

    def update_inputs_list_ui
      return if update_inputs_basic(false)
      if Input.repeat?(:UP)
        @uis[@index].move_index(-1)
      elsif Input.repeat?(:DOWN)
        @uis[@index].move_index(1)
      end
    end

    def update_inputs_type_matchups_ui
      if @selecting_type_list
        if Input.repeat?(:UP)
          @uis[@index].move_index(-1)
        elsif Input.repeat?(:DOWN)
          @uis[@index].move_index(1)
        elsif Input.repeat?(:LEFT)
          @uis[@index].move_group(-1)
        elsif Input.repeat?(:RIGHT)
          @uis[@index].move_group(1)
        end

        if Input.trigger?(:A)
          play_decision_se
          @selecting_type_list = false
          @uis[@index].selecting = false
          update_ctrl_state
        elsif Input.trigger?(:B)
          play_cancel_se
          @selecting_type_list = false
          @uis[@index].selecting = false
          update_ctrl_state
        end
        return
      end

      return if update_inputs_basic(false)

      if Input.trigger?(:A)
        play_decision_se
        @selecting_type_list = true
        @uis[@index].selecting = true
        update_ctrl_state
      end
    end

    def update_input_a_skill_ui
      return @selecting_move = true unless @selecting_move
      if @skill_index < 0
        @skill_index = @uis[@index].index
        @uis[@index].skills[@skill_index].moving = true
      else
        @uis[@index].skills[@skill_index].moving = false
        @pokemon.swap_skills_index(@uis[@index].index, @skill_index)
        @uis[3].data = @pokemon
        @uis[5].data = @pokemon
        @skill_index = -1
      end
    end

    def update_mouse_move_button
      return unless @index == 3 || @index == 5
      @uis[@index].skills.each_with_index do |skill, index|
        update_mouse_in_skill_button(skill, index)
      end
    end
  end
end

module Battle
  module Effects
    class Ability
      module PopupContext
        module_function

        def wrap_existing_subclasses!
          ObjectSpace.each_object(Class) do |klass|
            next unless klass < ::Battle::Effects::Ability
            wrap_class(klass)
          end
        end

        def wrap_class(klass)
          method_names = klass.instance_methods(false) + klass.private_instance_methods(false) + klass.protected_instance_methods(false)
          method_names.each do |method_name|
            next if method_name == :initialize
            alias_name = :"__dmc_popup_ctx_#{method_name}"
            next if klass.method_defined?(alias_name) || klass.private_method_defined?(alias_name) || klass.protected_method_defined?(alias_name)

            klass.class_eval do
              alias_method alias_name, method_name
              wrapped_name = alias_name
              define_method(method_name) do |*args, &block|
                previous = Thread.current[:dmc_ability_popup_db_symbol]
                Thread.current[:dmc_ability_popup_db_symbol] = @db_symbol
                send(wrapped_name, *args, &block)
              ensure
                Thread.current[:dmc_ability_popup_db_symbol] = previous
              end
            end
          end
        end
      end
    end
  end
end

Battle::Effects::Ability::PopupContext.wrap_existing_subclasses!

module PFM
  class PokemonBattler
    def ability_db_symbol
      db_symbol = Thread.current[:dmc_ability_popup_db_symbol]
      if db_symbol && battle_ability_db_symbols.include?(db_symbol)
        return db_symbol
      end

      return data_ability(ability || -1).db_symbol
    end
  end
end
