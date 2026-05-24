class Spriteset_Map
  # Plugin adding the fog effect to the Spriteset_Map
  module FogPlugin
    def init_sprites
      super
      @fog = condition_for_fog_repeat? ? Plane.new(@viewport1) : ShaderedSprite.new(@viewport1)
      @fog.z = 3000
    end
    private
    # Decide whether to use a repeating Plane for fog.
    # Set `FOG_REPEAT_SWITCH_ID` (integer) in another script to toggle repeating fog.
    def condition_for_fog_repeat?
      if defined?($game_switches) && defined?(FOG_REPEAT_SWITCH_ID) && FOG_REPEAT_SWITCH_ID.is_a?(Integer)
        $game_switches[FOG_REPEAT_SWITCH_ID]
      else
        false
      end
    end
    # Update some fog sprite parameters
    def update_fog_sprite_parameters
      @fog.zoom = ($game_map.fog_zoom / 100.0) * 0.5
      @fog.opacity = $game_map.fog_opacity.to_i
      @fog.blend_type = $game_map.fog_blend_type
      @fog.set_origin($game_map.display_x / 4 + $game_map.fog_ox, $game_map.display_y / 4 + $game_map.fog_oy)
      @fog.tone = $game_map.fog_tone
    end
  end
end
