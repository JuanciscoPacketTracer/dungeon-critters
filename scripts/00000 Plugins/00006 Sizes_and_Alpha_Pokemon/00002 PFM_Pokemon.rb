module PokemonSizes
  attr_accessor :alpha, :height_scalar, :weight_scalar

  def initialize(id, level, force_shiny = false, no_shiny = false, form = -1, opts = {})
    @alpha = opts[:alpha] || false
    @height_scalar = @alpha ? 255 : opts[:height_scalar] || rand(0..255)
    @weight_scalar = @alpha ? 255 : opts[:weight_scalar] || rand(0..255)
    super
  end

  # Return the height of the Pokemon
  # @return [Numeric] height
  def height
    create_size_scalars if @height_scalar.nil? || @weight_scalar.nil?

    base = data.height.to_f
    scalar = factor_formula(@height_scalar)
    height = base * scalar
    height *= alpha_multiplier if @alpha

    height.round(2)
  end

  # Return the weight of the Pokemon
  # @return [Numeric] weight
  def weight
    create_size_scalars if @height_scalar.nil? || @weight_scalar.nil?

    base = data.weight.to_f
    height_factor = factor_formula(@height_scalar)
    weight_factor = factor_formula(@weight_scalar)
    weight = base * height_factor * weight_factor
    weight *= alpha_multiplier if @alpha

    weight.round(2)
  end

  # Returns the size of the pokemon (XS, S, M, L, XL)
  # @return [String] the size
  def size
    create_size_scalars if @height_scalar.nil? || @weight_scalar.nil?
    avg_scalar = ((@height_scalar + @weight_scalar) / 2.0).round
    case avg_scalar
    when 0..15
      'XS'
    when 16..47
      'S'
    when 48..207
      'M'
    when 208..239
      'L'
    when 240..255
      'XL'
    end
  end

  # Adjusts weight and height to max scale for alphas
  def recalc_weight_height
    return unless @alpha

    @weight_scalar = 255
    @height_scalar = 255
  end

  private

  # Can set custom multipliers based on species
  # @return [Number] the size multiplier when alpha
  def alpha_multiplier
    return 1.0 if db_symbol == :basculegion

    Configs.pla_sa_config.alpha_size_multiplier
  end

  # Legends Arceus factor formula, used for heights and weights
  def factor_formula(scalar)
    (scalar / 255.0) * 0.40000004 + 0.8
  end

  # This is only called on older already existing mons and provides them with height/weight scalars
  def create_size_scalars
    return unless @height_scalar.nil? || @weight_scalar.nil? || @alpha.nil?

    @alpha = false if @alpha.nil?
    @height_scalar = rand(0..255) if @height_scalar.nil?
    @weight_scalar = rand(0..255) if @weight_scalar.nil?
  end
end

PFM::Pokemon.prepend(PokemonSizes)
