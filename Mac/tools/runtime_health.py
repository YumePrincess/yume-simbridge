"""Idle-only audio watchdog. It never fabricates readiness or restarts a call."""
class AudioWatchdog:
    def __init__(self): self.unhealthy_since = None
    def check(self, edge, audio, voice_started, wall, monotonic):
        if edge.get('busy') or not edge.get('modemConnected') or not 0<=wall*1000-edge.get('updated',0)<12000:
            self.unhealthy_since = None
            return False
        age = wall*1000-audio.get('updated',0)
        unhealthy = not voice_started or not (audio.get('ready') and 0<=age<4000)
        # A fresh but false Go route flag is repaired in place by the engine;
        # only missing/unresponsive CoreAudio or SMS-only startup needs restart.
        if not unhealthy:
            self.unhealthy_since = None
            return False
        if self.unhealthy_since is None: self.unhealthy_since=monotonic
        return monotonic-self.unhealthy_since>=15
