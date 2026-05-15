class Interpreter
  def enable_idle_animations
    $game_switches[Inva::Sw::IdlesEnabled] = true
  end

  def disable_idle_animations
    $game_switches[Inva::Sw::IdlesEnabled] = false
    $game_player.leave_idle_state if $game_player.state == :idle
  end
end
