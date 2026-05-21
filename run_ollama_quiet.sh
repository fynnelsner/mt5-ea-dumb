#!/bin/bash
# Ollama wrapper - redirects status output to file to prevent terminal blocking
# Usage: ./run_ollama_quiet.sh [ollama_args]

STATUS_FILE="ollama-status.md"

# Create/clear status file with header
echo "# Ollama Status Log" > "$STATUS_FILE"
echo "Started: $(date)" >> "$STATUS_FILE"
echo "" >> "$STATUS_FILE"

# Run ollama but redirect status/info messages to the file
# while keeping errors visible in terminal
ollama "$@" 2> >(
    while IFS= read -r line; do
        echo "[ERROR] $line" >> "$STATUS_FILE"
        echo "$line" >&2  # Also show errors in terminal
    done
) 1> >(
    while IFS= read -r line; do
        # Append to status file
        echo "$(date '+%Y-%m-%d %H:%M:%S') - $line" >> "$STATUS_FILE"
        # Only show minimal output in terminal (optional - comment out next line for silent mode)
        # echo "$line"  
    done
) &

OLLAMA_PID=$!
echo "Ollama running in background (PID: $OLLAMA_PID)"
echo "Status logged to: $STATUS_FILE"
echo "To view status: tail -f $STATUS_FILE"

# Trap to kill ollama on script exit
trap "kill $OLLAMA_PID 2>/dev/null; exit" INT TERM EXIT

# Keep script running if needed (optional)
# wait $OLLAMA_PID
