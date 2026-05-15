#======================================================================================================
# Battle general
module Battle
  class Move
    # Rewrite - Method calculating the damages done by the actual move
    def damages(user, target)
      log_data("\# damages(#{user}, #{target}) for #{db_symbol}")
      @effectiveness = 1
      @critical = logic.calc_critical_hit(user, target, critical_rate)
      log_data("@critical = #{@critical} \# critical_rate = #{critical_rate}")
      damage = user.level * 2 / 5 + 2
      log_data("damage = #{damage} \# #{user.level} * 2 / 5 + 2")
      damage = (damage * calc_base_power(user, target)).floor
      log_data("damage = #{damage} \# after calc_base_power")
      damage = (damage * calc_sp_atk(user, target)).floor / 50
      log_data("damage = #{damage} \# after calc_sp_atk / 50")
      damage = (damage / calc_sp_def(user, target)).floor
      log_data("damage = #{damage} \# after calc_sp_def")
      damage = (damage * calc_mod1(user, target)).floor + 2
      log_data("damage = #{damage} \# after calc_mod1 + 2")
      damage = (damage * calc_ch(user, target)).floor
      log_data("damage = #{damage} \# after calc_ch")
      damage = (damage * calc_mod2(user, target)).floor
      log_data("damage = #{damage} \# after calc_mod2")
      damage *= logic.move_damage_rng.rand(calc_r_range)
      damage /= 100
      log_data("damage = #{damage} \# after rng")
      types = definitive_types(user, target)
      damage = (damage * calc_stab(user, types)).floor
      log_data("damage = #{damage} \# after stab")
      if DMC::TypeRework::MAINTYPE
        damage = (damage * calc_type_final_multiplier(target, types)).floor
        log_data("damage = #{damage} \# after all types")
      else
        damage = (damage * calc_type_n_multiplier(target, :type1, types)).floor
        log_data("damage = #{damage} \# after type1")
        damage = (damage * calc_type_n_multiplier(target, :type2, types)).floor
        log_data("damage = #{damage} \# after type2")
        damage = (damage * calc_type_n_multiplier(target, :type3, types)).floor
        log_data("damage = #{damage} \# after type3")
      end
      damage = (damage * calc_mod3(user, target)).floor
      log_data("damage = #{damage} \# after mod3")
      target_hp = target.effects.get(:substitute).hp if target.effects.has?(:substitute) && !user.has_ability?(:infiltrator) && !authentic?
      target_hp ||= target.hp
      damage = damage.clamp(1, target_hp)
      log_data("damage = #{damage} \# after clamp")
      return damage
    end
    
    # Function that calculate the type modifier (for specific uses)
    alias dmc_battleMove_typeModifier type_modifier
    def type_modifier(user, target)
      types = definitive_types(user, target)
      if DMC::TypeRework::MAINTYPE
        n = calc_type_final_multiplier(target, types)
      else
        n = dmc_battleMove_typeModifier(user, target)
      end
      return n
    end
    
    # Rewrite - STAB calculation
    def calc_stab(user, types)
      move_types = types.reject(&:zero?)
      
      return 1 if move_types.none? { |type| user.type?(type) }
      
      if DMC::TypeRework::MAINTYPE && types.none? { |type| user.type1 == type }
        return 1.5 if user.has_ability?(:adaptability)
        return 1.25
      else
        return 2 if user.has_ability?(:adaptability)
        return 1.5
      end
    end
  
  # Calcs the type effectiveness modifier when using the "main type" option
    def calc_type_final_multiplier(target, types)
      mod = 0
      %i[type1 type2 type3].each do |type_id|
        target_type = target.send(type_id)
        type_id == :type1 ? mult = 2 : mult = 1
        result = types.inject(1) { |product, type| product * calc_single_type_multiplier(target, target_type, type) }
        if result == 0
          @effectiveness *= 0 if @effectiveness >= 0
          return 0
        elsif result < 0
          return 1
        elsif result > 1
          mod += mult
        elsif result < 1
          mod -= mult
        end
        puts("#{target_type} (#{types}) mod: #{mod}")
      end
      if mod >= 4
        @effectiveness *= 4
        return 4
      elsif mod == 3
        @effectiveness *= 3
        return 3
      elsif mod == 1 || mod == 2
        @effectiveness *= 2
        return 2
      elsif mod == 0
        @effectiveness *= 1
        return 1
      elsif mod == -1 || mod == -2
        @effectiveness *= 0.5
        return 0.5
      elsif mod == -3
        @effectiveness *= 0.33
        return 0.33
      else
        @effectiveness *= 0.25
        return 0.25
      end
    end
  end
end