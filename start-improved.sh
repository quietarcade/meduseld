#!/bin/bash
# Improved Icarus server startup script with better error handling

SESSION="icarus"
GAME_DIR="/srv/games/icarus"
LOG_FILE="$GAME_DIR/startup.log"

# Function to log messages
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "========================================="
log "Starting Icarus Server"
log "========================================="

cd "$GAME_DIR" || {
    log "ERROR: Cannot change to game directory: $GAME_DIR"
    exit 1
}

# Check if server process is already running
if pgrep -f "IcarusServer-Win64-Shipping.exe" > /dev/null; then
    log "ERROR: Server process is already running"
    log "Stop the server first before starting a new instance"
    exit 1
fi

# Check if tmux session exists
if tmux has-session -t $SESSION 2>/dev/null; then
    log "Tmux session '$SESSION' already exists"
    
    # Check if the server process is actually running inside
    if tmux capture-pane -t $SESSION -p | grep -q "IcarusServer"; then
        log "ERROR: Server appears to be running in tmux session"
        log "Attach with: tmux attach -t $SESSION"
        exit 1
    else
        log "Tmux session exists but server not running - killing stale session"
        tmux kill-session -t $SESSION
        sleep 2
    fi
fi

# Check if ports are already in use
if netstat -tuln 2>/dev/null | grep -q ":17777 "; then
    log "ERROR: Port 17777 already in use"
    log "Another process is using the game server port"
    netstat -tulpn 2>/dev/null | grep ":17777"
    exit 1
fi

if netstat -tuln 2>/dev/null | grep -q ":27015 "; then
    log "ERROR: Port 27015 already in use"
    log "Another process is using the query port"
    netstat -tulpn 2>/dev/null | grep ":27015"
    exit 1
fi

# Check if Wine is available
if ! command -v wine &> /dev/null; then
    log "ERROR: Wine is not installed or not in PATH"
    exit 1
fi

# Check if xvfb-run is available
if ! command -v xvfb-run &> /dev/null; then
    log "ERROR: xvfb-run is not installed"
    log "Install with: sudo apt-get install xvfb"
    exit 1
fi

# Check if server executable exists
if [ ! -f "$GAME_DIR/Icarus/Binaries/Win64/IcarusServer-Win64-Shipping.exe" ]; then
    log "ERROR: Server executable not found"
    exit 1
fi

# Fix Wine drive mappings if needed
if [ ! -d "$HOME/.wine" ]; then
    log "Initializing Wine prefix..."
    WINEDEBUG=-all wineboot -u 2>/dev/null
fi

log "All checks passed - starting server in tmux session '$SESSION'"

# Set Wine environment variables to fix drive mapping issues
export WINEDEBUG=-all  # Suppress Wine debug messages
export WINEPREFIX="$HOME/.wine"  # Ensure consistent Wine prefix

# Create a wrapper script that will log the exit and monitor Wine
WRAPPER_SCRIPT="$GAME_DIR/.server_wrapper.sh"
cat > "$WRAPPER_SCRIPT" << 'WRAPPER_EOF'
#!/bin/bash
LOG_FILE="/srv/games/icarus/startup.log"
cd /srv/games/icarus
export WINEPREFIX=$HOME/.wine

# Log Wine version and configuration
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Wine version: $(wine --version 2>&1)" | tee -a "$LOG_FILE"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Wine prefix: $WINEPREFIX" | tee -a "$LOG_FILE"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Xvfb display: $DISPLAY" | tee -a "$LOG_FILE"

# Enable Wine error logging but suppress common noise
export WINEDEBUG=err+all

# Start the server and capture Wine output
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting Wine process..." | tee -a "$LOG_FILE"

xvfb-run -a wine ./Icarus/Binaries/Win64/IcarusServer-Win64-Shipping.exe /Game/Maps/DedicatedServerEntry -Port=17777 -PeerPort=17778 -QueryPort=27015 -SteamServerName='404localserver' -log 2>&1 | while IFS= read -r line; do
    # Filter out known harmless Wine messages
    if [[ "$line" =~ "Read access denied" ]] || [[ "$line" =~ "FS volume label" ]]; then
        continue
    fi
    # Only log Wine errors, skip warnings and fixme
    if [[ "$line" =~ "err:" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] WINE ERROR: $line" | tee -a "$LOG_FILE"
    fi
done

# Capture exit code
EXIT_CODE=$?

# Log the exit
echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⏹ Server process exited with code: $EXIT_CODE" | tee -a "$LOG_FILE"

if [ $EXIT_CODE -eq 0 ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ Clean shutdown" | tee -a "$LOG_FILE"
elif [ $EXIT_CODE -eq 137 ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✗ Server was killed (SIGKILL)" | tee -a "$LOG_FILE"
elif [ $EXIT_CODE -eq 139 ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 💥 Server crashed (Segmentation fault)" | tee -a "$LOG_FILE"
elif [ $EXIT_CODE -eq 143 ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✗ Server was terminated (SIGTERM)" | tee -a "$LOG_FILE"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✗ Abnormal termination (exit code: $EXIT_CODE)" | tee -a "$LOG_FILE"
fi

# Check if Wine is still running (shouldn't be)
if pgrep -f "wine.*IcarusServer" > /dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: Wine process still running after exit" | tee -a "$LOG_FILE"
fi

bash
WRAPPER_EOF

chmod +x "$WRAPPER_SCRIPT"

# Start the server in tmux using the wrapper
tmux new-session -d -s $SESSION "$WRAPPER_SCRIPT"

# Wait a moment and check if it's still running
sleep 3

if ! tmux has-session -t $SESSION 2>/dev/null; then
    log "ERROR: Tmux session died immediately after starting"
    log "Check Wine and xvfb installation"
    exit 1
fi

# Verify the process actually started
log "Waiting for server process to initialize..."
for i in {1..10}; do
    if pgrep -f "IcarusServer-Win64-Shipping.exe" > /dev/null; then
        PID=$(pgrep -f 'IcarusServer-Win64-Shipping.exe')
        log "✓ Server process confirmed running (PID: $PID)"
        log "✓ Tmux session '$SESSION' is active"
        log "✓ Server started successfully"
        log "Attach with: tmux attach -t $SESSION"
        log "View logs: tail -f $GAME_DIR/Icarus/Saved/Logs/Icarus.log"
        
        # Start a background monitor that logs process health
        (
            sleep 30  # Wait 30 seconds before first check
            while pgrep -f "IcarusServer-Win64-Shipping.exe" > /dev/null; do
                PID=$(pgrep -f 'IcarusServer-Win64-Shipping.exe' | head -1)
                if [ -n "$PID" ] && ps -p $PID > /dev/null 2>&1; then
                    CPU=$(ps -p $PID -o %cpu= 2>/dev/null | awk '{print $1}')
                    MEM=$(ps -p $PID -o %mem= 2>/dev/null | awk '{print $1}')
                    THREADS=$(ps -p $PID -o nlwp= 2>/dev/null | awk '{print $1}')
                    
                    # Only log if we got valid numeric data
                    if [ -n "$CPU" ] && [ -n "$MEM" ] && [ -n "$THREADS" ] && echo "$CPU" | grep -qE '^[0-9.]+$' && echo "$MEM" | grep -qE '^[0-9.]+$' && echo "$THREADS" | grep -qE '^[0-9]+$'; then
                        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Process health: PID=$PID CPU=${CPU}% MEM=${MEM}% Threads=$THREADS" >> "$LOG_FILE"
                    fi
                fi
                sleep 300  # Check every 5 minutes
            done
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Process monitor: Server process no longer running" >> "$LOG_FILE"
        ) &
        
        exit 0
    fi
    sleep 1
done

log "WARNING: Server process not detected after 10 seconds"
log "The server may still be initializing - check tmux session"
log "Attach with: tmux attach -t $SESSION"
exit 0
