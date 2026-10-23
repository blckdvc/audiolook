#!/bin/bash
cd "$(dirname "$0")"
LOG="build.log"
{ echo "=== $(date) ==="; ./build.sh; echo "EXIT=$?"; echo "=== FIN ==="; } > "$LOG" 2>&1
echo "Terminé — voir build.log"
