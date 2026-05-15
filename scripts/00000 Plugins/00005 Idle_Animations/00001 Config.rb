module Configs
  # Configuration class for Idle Animations
  class IdleAnimations
    attr_accessor :default_switch, :delay_before_idle, :speed, :frequency

    def initialize
      # Switch to enable/disable the system
      @default_switch = 201
      # How many frames before idle animations start
      @delay_before_idle = 60
      # Speed of animation
      @speed = 3
      # Frequency of animation
      @frequency = 4
    end
  end
  register(:idle_animations, 'plugins/idle_animations', :yml, true, IdleAnimations)
end
