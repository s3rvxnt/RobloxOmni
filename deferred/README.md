# Deferred Stage (Ring 4)

Scripts placed in this folder run after all startup activity and network idle complete, yielding with an intentional buffer to prevent competing for CPU resources during initial rendering.

### Best Used For:
* Long-running background telemetry & analytics
* Low-priority cache garbage collection & cleaner loops
* Discord webhook stat reporters
* Delayed anti-idle / keepalive bots
