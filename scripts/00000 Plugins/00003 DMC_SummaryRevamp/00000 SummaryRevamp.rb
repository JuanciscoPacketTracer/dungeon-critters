module UI
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
      @extend_data = extend_data
    end

    def create_uis
      @uis = [
        UI::Summary_Memo.new(@viewport),
        UI::Summary_Stat.new(@viewport),
        UI::Summary_Abilities.new(@viewport),
        UI::Summary_Skills.new(@viewport),
        UI::Summary_Contest.new(@viewport)
      ]
    end

    def last_state
      last_index = 4
      last_index -= 1 while last_index > 0 && !ui_available?(@uis[last_index])
      return last_index
    end

    def update_ctrl_state
      @base_ui.mode = ctrl_id_state
      @uis[4].show_page_version(@selecting_move ? :moves : :stats) if @index == 4
    end

    def update_ui_visibility
      @uis.each_with_index { |ui, index| ui.visible = index == @index }
      update_ctrl_state
    end

    def ctrl_id_state
      case @index
      when 0
        return 0 unless @pokemon.is_a?(PFM::PokemonBattler)
        return 7
      when 1, 2
        return 1
      when 3
        return 5 if @mode == :skill
        return 4 if @skill_index >= 0
        return 3 if @selecting_move
        return 2 unless @pokemon.is_a?(PFM::PokemonBattler)
        return 8
      when 4
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
      when 3, 4
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

    def update_input_a_skill_ui
      return @selecting_move = true unless @selecting_move
      if @skill_index < 0
        @skill_index = @uis[@index].index
        @uis[@index].skills[@skill_index].moving = true
      else
        @uis[@index].skills[@skill_index].moving = false
        @pokemon.swap_skills_index(@uis[@index].index, @skill_index)
        @uis[3].data = @pokemon
        @uis[4].data = @pokemon
        @skill_index = -1
      end
    end

    def update_mouse_move_button
      return unless @index == 3 || @index == 4
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