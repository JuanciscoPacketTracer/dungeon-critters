module BattleUI
  class InfoBar < UI::SpriteStack
    def create_type_sprite
      @type1_sprite = add_sprite(*type1_coordinates, NO_INITIAL_IMAGE, type: BattleType1Sprite)
      @type2_sprite = add_sprite(*type2_coordinates, NO_INITIAL_IMAGE, type: BattleType2Sprite)
      @type3_sprite = add_sprite(*type3_coordinates, NO_INITIAL_IMAGE, type: BattleType3Sprite)
    end

    def type1_coordinates
      return -20, -7 if enemy?

      return 135, 0
    end

    def type2_coordinates
      return -20, 10 if enemy?

      return 135, 17
    end

    def type3_coordinates
      return -8, 2 if enemy?

      return 148, 10
    end

    def type3_triangle_coordinates
      return -8, 2 if enemy?

      return 148, 10
    end
  end
end

module SpritePatch
  def create_sprites
    super
    create_type_sprite
  end

  def data=(pokemon)
    super
    reposition_type_sprites_dynamic(pokemon)
  end

  private

  def reposition_type_sprites_dynamic(pokemon)
    return unless @sprites && pokemon

    type1_sprite = @sprites.find { |s| s.is_a?(BattleType1Sprite) }
    type2_sprite = @sprites.find { |s| s.is_a?(BattleType2Sprite) }
    type3_sprite = @sprites.find { |s| s.is_a?(BattleType3Sprite) }

    return unless type1_sprite && type2_sprite && type3_sprite

    if pokemon.type3 != 0
      type1_sprite.x, type1_sprite.y = type1_coordinates
      type2_sprite.x, type2_sprite.y = type3_triangle_coordinates
      type3_sprite.x, type3_sprite.y = type3_coordinates
      type3_sprite.visible = true
    else
      type1_sprite.x, type1_sprite.y = type1_coordinates
      type2_sprite.x, type2_sprite.y = type2_coordinates
      type3_sprite.visible = false
    end
  end
end

module BattleUI
  class InfoBar < UI::SpriteStack
    prepend SpritePatch
  end
end