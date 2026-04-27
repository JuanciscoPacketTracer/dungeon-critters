# Redefine the 3rd type for each creature
module PFM
  class Pokemon
    # Third type ID of the Pokemon
    # @return [Integer]
    attr_writer :type3

    
    # Rewrite - Return the current third type of the Pokemon
    # @return [Integer]
    def type3
      #data_type(data.type3).id
      key = [db_symbol, form]
      return data_type(DMC::TypeRework::CREATURE_TYPE_3[key]).id
    end
  end
end


module PFM
  class Quests
    class Quest
      # Rewrite - Check if catch pokemon quest is completed
      def objective_catch_pokemon_test(pkm, pokemon)
        return pokemon.id == pkm unless pkm.is_a?(Hash)
        return false if pkm[:id] && !(pokemon.id == pkm[:id] || pokemon.db_symbol == pkm[:id])
        return false if pkm[:nature] && pokemon.nature_id != data_nature(pkm[:nature]).id
        return false if pkm[:type] && pokemon.type1 != data_type(pkm[:type]).id && pokemon.type2 != data_type(pkm[:type]).id && pokemon.type3 != data_type(pkm[:type]).id
        return false if pkm[:type2] && pokemon.type1 != data_type(pkm[:type2]).id && pokemon.type2 != data_type(pkm[:type2]).id && pokemon.type3 != data_type(pkm[:type2]).id
        return false if pkm[:min_level] && pokemon.level <= pkm[:min_level]
        return false if pkm[:max_level] && pokemon.level >= pkm[:max_level]
        return false if pkm[:level] && pokemon.level != pkm[:level]
        return true
      end
    end
  end
end