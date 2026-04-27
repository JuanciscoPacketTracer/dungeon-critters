module AlphasInTheWild
  # Configure the wild battle
  # @param enemy_arr [Array<PFM::Pokemon>]
  # @param battle_id [Integer] ID of the events to load for battle scenario
  # @return [Battle::Logic::BattleInfo]
  def configure_battle(enemy_arr, battle_id)
    puts 'test :)'
    return if (!enemy_arr.is_a? Array) || !enemy_arr || enemy_arr&.empty?

    if Configs.pla_sa_config.wild_alphas
      rate = Configs.pla_sa_config.wild_alpha_rate
      enemy_arr.each do |pokemon|
        next unless pokemon.is_a?(PFM::Pokemon)

        if rand(rate).zero? # 1 / rate chance
          pokemon.alpha = true
          pokemon.recalc_weight_height
        end
      end
    end
    super
  end
end

PFM::Wild_Battle.prepend(AlphasInTheWild)
