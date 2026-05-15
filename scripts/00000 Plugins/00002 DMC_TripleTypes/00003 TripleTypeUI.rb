module UI
  # Sprite that show the 3rd type of the Pokemon
  class Type3Sprite < Type1Sprite
    private

    # Retrieve the data source of the type sprite
    # @return [Symbol]
    def data_source
      :type3
    end
  end

  # Rewrite - Creates the sprites of the dex window
  class DexWinInfo
    def create_sprites
      # Change background image
      add_background('WinInfos_3type')
      add_sprite(8, 4, 'Catch')
      add_text(29, 4, 116, 16, $options.language == 'fr' ? :form_name : :form_name_upper, type: SymText, color: 10)
      add_text(9, 27, 116, 16, :pokedex_species, type: SymText)
      add_text(9, 67, 116, 16, :pokedex_weight, type: SymText)
      add_text(9, 87, 116, 16, :pokedex_height, type: SymText)
      # Reposition 1st and 2nd type sprites
      add_sprite(15, 47, NO_INITIAL_IMAGE, true, type: Type1Sprite)
      add_sprite(69, 47, NO_INITIAL_IMAGE, true, type: Type2Sprite)
      # Add 3rd type sprite
      add_sprite(122, 47, NO_INITIAL_IMAGE, true, type: Type3Sprite)
    end
  end

  # Rewrite - Creates the sprites of summary screen
  class Summary_Memo
    alias dmc_summarymemo_initmemo init_memo
    def init_memo
      texts = text_file_get(27)
      with_surface(114, 19, 95) do
        add_line(0, texts[2])
        no_egg add_line(1, texts[0])
        @level_text = no_egg(add_line(1, texts[29], dx: 1))
        no_egg add_line(2, texts[3])
        no_egg add_line(3, texts[8])
        no_egg add_line(3, texts[9], dx: 1)
        no_egg add_line(4, texts[10])
        no_egg add_line(5, texts[12])
        no_egg add_line(6, text_get(23, 7))
        with_font(20) { no_egg add_text(11, 125, 56, nil, 'EXP') }
        add_line(0, :name, 2, type: SymText, color: 1, dx: 1)
        @id = no_egg add_line(1, :id_text, 2, type: SymText, color: 1)
        @level_value = no_egg(add_line(1, :level_text, 2, type: SymText, color: 1, dx: 1))
        no_egg add_line(3, :trainer_id_text, 2, type: SymText, color: 1, dx: 1)
        no_egg add_line(4, :exp_text, 2, type: SymText, color: 1, dx: 1)
        no_egg add_line(5, :exp_remaining_text, 2, type: SymText, color: 1, dx: 1)
        no_egg add_line(6, :item_name, 2, type: SymText, color: 1, dx: 1)
      end
      no_egg add_text(114, 19 + 16 * 3, 92, 16, :trainer_name, 2, type: SymText, color: 1)
      # Reposition 1st and 2nd type sprites
      no_egg push(207, 19 + 34, nil, type: Type1Sprite)
      no_egg push(241, 19 + 34, nil, type: Type2Sprite)
      # Add 3rd type sprite
      no_egg push(275, 19 + 34, nil, type: Type3Sprite)
    end
  end

  # Rewrite - Creates the sprites of summary screen in pc box
  module Storage
    class Summary
      def create_pokemon
        no_egg @id_text = add_text(2, 17, 0, 16, :id_text, color: 10, type: SymText)
        @id_text.z = 6
        add_text(15, 25, 79, 15, :name, 1, color: 10, type: SymText).z = 6
        @sprite = add_sprite(55, 142, NO_INITIAL_IMAGE, type: UI::PokemonFaceSprite).set_z(6)
        add_text(15, 143, 79, 15, :given_name, 1, color: 10, type: SymText).z = 6
        no_egg add_sprite(96, 146, NO_INITIAL_IMAGE, type: UI::GenderSprite).set_z(6)
        no_egg add_sprite(62, 161, 'pc/lv_')
        no_egg add_text(76, 62, 0, 15, :level_text, color: 10, type: SymText)
        # Reposition 1st and 2nd type sprites
        no_egg add_sprite(5, 172, NO_INITIAL_IMAGE, type: UI::Type1Sprite).set_z(6)
        no_egg add_sprite(39, 172, NO_INITIAL_IMAGE, type: UI::Type2Sprite).set_z(6)
        # Add 3rd type sprite
        no_egg add_sprite(73, 172, NO_INITIAL_IMAGE, type: UI::Type3Sprite).set_z(6)
        no_egg @shiny_icon = add_sprite(11, 52, 'shiny')
        @shiny_icon.set_z(6)
        no_egg @pokerus_icon = add_sprite(87, 51, 'icon_pokerus_affected')
        @pokerus_icon.set_z(6)
        @transitionning_texts = [add_text(8, 189, 0, 15, :nature_text, color: 10, type: SymText),
                                  add_text(8, 189, 0, 15, :ability_name, color: 10, type: SymText), add_text(8, 189, 0, 15, :item_name, color: 10, type: SymText)]
        @transitionning_texts.each { |text| no_egg(text) }
      end
    end
  end
end