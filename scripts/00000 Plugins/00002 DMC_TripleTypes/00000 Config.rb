module DMC
  module TypeRework
    # Constant defining if you are using the rebalanced effectiveness calculation (true) or not (false)
    MAINTYPE = true


    # Constant defining the Type3 of a Pokemon by form
    # @return [Hash{ Array<Symbol, Integer> => Symbol }
    # Example: [:bulbasaur, 0] => :fire
    CREATURE_TYPE_3 = {
      [:bulbasaur, 0] => :fire,
      [:charmander, 0] => :ghost
    }
    CREATURE_TYPE_3.default = :__undef__
  end
end