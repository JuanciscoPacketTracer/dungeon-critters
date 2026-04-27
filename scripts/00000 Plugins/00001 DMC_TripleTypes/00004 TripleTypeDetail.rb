module PFM
  class PokemonBattler
    # Add type3 to the properties that Transform copies
    TRANSFORM_BP_METHODS << :type3
  end
end

module Battle
  class Move
    class Conversion
      # Conversion also removes 3rd type
      alias dmc_moveConversion_dealEffect deal_effect
      def deal_effect(user, actual_targets)
        dmc_moveConversion_dealEffect(user, actual_targets)
        actual_targets.first.type3 = 0
      end
    end

    class Conversion2
      # Conversion2 also removes 3rd type
      alias dmc_moveConversion2_dealEffect deal_effect
      def deal_effect(user, actual_targets)
        dmc_moveConversion2_dealEffect(user, actual_targets)
        user.type3 = 0
      end
    end

    # Rewrite - ReflectType copies all target's types
    class ReflectType
      def deal_effect(user, actual_targets)
        target = actual_targets.first
        return if target.typeless?
        return if always_failing_target.include?(target.db_symbol)
        user.type1 = target.type1 == 0 && target.type2 == 0 && target.type3 == 0 ? 1 : target.type1
        user.type2 = target.type2
        user.type3 = target.type3
        logic.scene.display_message_and_wait(message(user, target))
      end
    end

    # Calculate the multiplier needed to get the damage factor of the Stealth Rock
    class StoneAxe
      alias dmc_moveStoneAxe_calcFactor calc_factor
      def calc_factor(target)
        type = [self.type]
        @effectiveness = -1
        if DMC::TypeRework::MAINTYPE
          n = calc_type_final_multiplier(target, type)
        else
          n = dmc_moveStoneAxe_calcFactor(target)
        end
        return n
      end
    end

    # Calculate the multiplier needed to get the damage factor of the Stealth Rock
    class StealthRock
      alias dmc_moveStealthRock_calcFactor calc_factor
      def calc_factor(target)
        type = [self.type]
        @effectiveness = -1
        if DMC::TypeRework::MAINTYPE
          n = calc_type_final_multiplier(target, type)
        else
          n = dmc_moveStealthRock_calcFactor(target)
        end
        return n
      end
    end
  end
end