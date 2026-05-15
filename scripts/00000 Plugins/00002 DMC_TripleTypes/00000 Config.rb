module DMC
  module TypeRework
    # Constant defining if you are using the rebalanced effectiveness calculation (true) or not (false)
    MAINTYPE = true


    # Constant defining the Type3 of a Pokemon by form
    # @return [Hash{ Array<Symbol, Integer> => Symbol }
    # Example: [:bulbasaur, 0] => :fire
    CREATURE_TYPE_3 = {
      [:battling, 0] => :flying,
      [:nibblet, 0] => :flying,
      [:echobat, 0] => :flying,
      [:sonarion, 0] => :flying,
      [:xenobat, 0] => :flying,
      [:overseer, 0] => :mind,
      [:hellbat, 0] => :flying,
      [:hellwing, 0] => :fire,
      [:lamplet, 0] => :steel,
      [:amplet, 0] => :steel,
      [:luxion, 0] => :steel,
      [:wicklet, 0] => :luz,
      [:wicklabra, 0] => :luz,
      [:lunaryx, 0] => :luz,
      [:mourndelume, 0] => :dark,
      [:waxy, 0] => :luz,
      [:hivewax, 0] => :luz,
      [:meltqueen, 0] => :royal,
      [:combuxtix, 0] => :poison,
      [:primawurlm, 0] => :dragon,
      [:toadrum, 0] => :music,
      [:toadossal, 0] => :music,
      [:sunshroom, 0] => :holy,
      [:ironmula, 0] => :steel,
      [:sanchariot, 0] => :royal,
      [:burriesta, 0] => :dream,
    }
    CREATURE_TYPE_3.default = :__undef__
  end
end