/// Apple QA1749 requires a later user action before setActive after media reset.
/// Keep that gate independent of the displayed error: another failure or a
/// foreground/route/stop callback must not accidentally authorize activation.
struct PetOverlayAudioRecoveryState {
  var interrupted = false
  private(set) var requiresUserAction = false

  var blocker: String? {
    if requiresUserAction { return "overlay_media_reset" }
    return interrupted ? "overlay_audio_interrupted" : nil
  }

  mutating func mediaServicesReset() {
    interrupted = false
    requiresUserAction = true
  }

  mutating func retry(userInitiated: Bool) {
    interrupted = false
    if userInitiated { requiresUserAction = false }
  }
}

