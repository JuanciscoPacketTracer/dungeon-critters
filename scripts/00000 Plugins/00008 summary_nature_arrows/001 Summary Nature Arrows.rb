# Summary Nature Arrows
#
# Author : Raty
# License : MIT
#
# Simple PSDK plugin that shows an up arrow and a down arrow
# next to stats affected by the Pokemon's nature in the Summary stat page.
#
# Notes:
# - By default, this script uses:
#   - graphics/interface/summary/arrow_up.png
#   - graphics/interface/summary/arrow_down.png
# - Only the Summary stat page is affected.

module SummaryNatureArrows
  # Asset used for the stat increased by the nature.
  UP_ARROW_IMAGE = 'summary/arrow_up'
  # Asset used for the stat decreased by the nature.
  DOWN_ARROW_IMAGE = 'summary/arrow_down'
  # Horizontal offset applied after the stat label width.
  ARROW_OFFSET_X = 2
  # Vertical offset applied from the stat label position.
  ARROW_OFFSET_Y = 5

  module_function

  # Return the arrow state for each nature-affected stat.
  # Order: Attack, Defense, Sp. Atk, Sp. Def, Speed.
  # @param pokemon [PFM::Pokemon]
  # @return [Array<Symbol, nil>]
  def states_for(pokemon)
    # PSDK stores HP in the middle of the partition array, so we skip index 3
    # to get the five non-HP stats in Summary order.
    nature = pokemon.nature.partition.with_index { |_, i| i != 3 }.flatten(1)
    1.upto(5).map do |i|
      next :up if nature[i] > 100
      next :down if nature[i] < 100

      nil
    end
  end

  # Return the asset matching an arrow state.
  # @param state [Symbol]
  # @return [String]
  def image_for(state)
    return UP_ARROW_IMAGE if state == :up

    DOWN_ARROW_IMAGE
  end
end

module UI
  class Summary_Stat < SpriteStack
    module SummaryNatureArrowsPatch
      # Refresh the nature arrows each time the shown Pokemon changes.
      # @param pokemon [PFM::Pokemon]
      def data=(pokemon)
        super
        refresh_nature_arrows(pokemon)
      end

      private

      # Create the arrow sprites after the original stat labels are initialized.
      def init_stats
        super
        create_nature_arrows
      end

      # Create hidden arrow sprites reused for every Pokemon shown by the summary.
      # Opacity is used instead of visibility because the summary can restore
      # child visibility while switching from one Pokemon to another.
      def create_nature_arrows
        @nature_arrows = 5.times.map do
          sprite = add_sprite(0, 0, nil)
          sprite.opacity = 0
          sprite
        end
      end

      # Update arrow visibility and position according to the Pokemon nature.
      # @param pokemon [PFM::Pokemon]
      def refresh_nature_arrows(pokemon)
        @nature_arrows.each { |sprite| sprite.opacity = 0 }

        SummaryNatureArrows.states_for(pokemon).each_with_index do |state, index|
          next unless state

          sprite = @nature_arrows[index]
          label = @stat_name_texts[index]
          sprite.set_bitmap(SummaryNatureArrows.image_for(state), :interface)
          sprite.set_position(
            label.x + label.real_width + SummaryNatureArrows::ARROW_OFFSET_X,
            label.y + SummaryNatureArrows::ARROW_OFFSET_Y
          )
          sprite.z = label.z
          sprite.opacity = 255
        end
      end
    end

    prepend SummaryNatureArrowsPatch
  end
end
