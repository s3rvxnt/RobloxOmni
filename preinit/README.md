# PreInit Stage (Ring 1)

Scripts placed in this folder run **immediately upon injection** as soon as the `game` DataModel exists (`game ~= nil`), before the game finishes loading.

### Best Used For:
* Network interceptors & remote spies
* Anticheat bypasses & environment hooks
* Critical utility libraries
* Size detection & early game patches
