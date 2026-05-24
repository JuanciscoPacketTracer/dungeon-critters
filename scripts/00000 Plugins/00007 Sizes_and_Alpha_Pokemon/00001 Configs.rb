module Configs
  class PLASizesAndAlphas
    attr_accessor :alpha_size_multiplier, :wild_alphas, :wild_alpha_rate

    def initialize
      @alpha_size_multiplier = 2.25
      @wild_alphas = false
      @wild_alpha_rate = 100 # 1 / 100
    end
  end
  register(:pla_sa_config, 'plugins/pla_sizes_and_alphas', :yml, false, PLASizesAndAlphas)
end
