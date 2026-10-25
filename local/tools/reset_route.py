#!/usr/bin/env python3
import voice_runtime
voice_runtime.stop_voice_route()
voice_runtime.ensure_voice_route(force=True)
print('Voice route ready', flush=True)
