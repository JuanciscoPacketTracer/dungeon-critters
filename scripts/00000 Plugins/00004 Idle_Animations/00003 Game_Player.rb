class Game_Player < Game_Character
  STATE_MOVEMENT_INFO[:idle] = [Configs.idle_animations.speed, Configs.idle_animations.frequency]
end

module IdleSprites
  # Number of frames before idle animation starts
  IDLE_DELAY = Configs.idle_animations.delay_before_idle

  def initialize(*args)
    super
    @idle_timer = 0
  end

  # Returns the state the player is in
  # @return [Boolean] state the player is in
  def state
    return @state
  end

  def update
    super
    leave_idle_state if Input.trigger?(:A)
    update_idlesprites
  end

  def refresh
    super
    update_idlesprites
  end

  def enter_in_idle_state
    @state = :idle
    update_move_parameter(:idle)
    update_appearance(@pattern)
    @step_anime = true
    @character_name = @charset_base + '_idle'
    log_debug('Entered idle state')
  end

  def leave_idle_state
    @idle_timer = 0
    if @state == :idle
      @state = :walking
      @character_name = @charset_base + '_walk'
      @step_anime = false
      log_debug('Exited idle state')
    end
  end

  def update_idlesprites
    return unless $game_switches[Inva::Sw::IdlesEnabled]
    return unless @charset_base
    return if $game_system.map_interpreter.running?

    @idle_timer ||= 0
    if moving? || Input.dir4 != 0
      @idle_timer = 0
      leave_idle_state
    else
      return if surfing? || cycling?

      @idle_timer += 1
      enter_in_idle_state if @idle_timer >= IDLE_DELAY && @state != :idle
    end
  end
end

# Prepend it so our methods override the originals but can call super
Game_Player.prepend(IdleSprites)
