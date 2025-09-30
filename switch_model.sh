#!/usr/bin/env bash
set -euo pipefail

# --- Enhanced Configuration ---
MODELS_DIR="$(pwd)/models"
SYMLINK="${MODELS_DIR}/current"
CONTAINER_NAME="ampere-llama-server"
HEALTH_URL="http://localhost:8080/v1/models"
MAX_WAIT=120                              # Increased wait time for large models
SLEEP=3                                   # Slightly longer between polls
LOG_LINES=50                              # More focused log output
BACKUP_SYMLINK="${MODELS_DIR}/.current_backup"
LOCK_FILE="/tmp/model_switcher.lock"

# --- Color output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Helper functions ---
log() { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
error() { echo -e "${RED}✗${NC} $*" >&2; }
die() { error "$*"; cleanup; exit 1; }

cleanup() {
    [ -f "$LOCK_FILE" ] && rm -f "$LOCK_FILE"
}

# Set up cleanup trap
trap cleanup EXIT INT TERM

# --- Validation ---
if [ -f "$LOCK_FILE" ]; then
    die "Another instance is already running (lock file exists: $LOCK_FILE)"
fi
echo $$ > "$LOCK_FILE"

if [ ! -d "$MODELS_DIR" ]; then
    die "Models directory not found: $MODELS_DIR"
fi

# Check if Docker is running
if ! docker info >/dev/null 2>&1; then
    die "Docker is not running or not accessible"
fi

# --- Gather and display models ---
log "Scanning for GGUF models in $MODELS_DIR..."
mapfile -t MODELS < <(find "$MODELS_DIR" -maxdepth 1 -type f -iname "*.gguf" -printf "%f\n" | sort)

if [ ${#MODELS[@]} -eq 0 ]; then
    die "No .gguf files found in $MODELS_DIR"
fi

# Show current model if symlink exists
CURRENT_MODEL=""
if [ -L "$SYMLINK" ]; then
    CURRENT_TARGET=$(readlink "$SYMLINK" 2>/dev/null || true)
    if [ -n "$CURRENT_TARGET" ]; then
        # Handle both relative and absolute symlinks
        if [[ "$CURRENT_TARGET" == /* ]]; then
            CURRENT_MODEL=$(basename "$CURRENT_TARGET")
        else
            CURRENT_MODEL="$CURRENT_TARGET"
        fi
        success "Currently loaded model: $CURRENT_MODEL"
    fi
else
    warn "No current model symlink found"
fi

# Check container status
CONTAINER_RUNNING=false
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    CONTAINER_RUNNING=true
    success "Container '$CONTAINER_NAME' is running"
else
    warn "Container '$CONTAINER_NAME' is not running"
fi

echo
echo "Available models in $MODELS_DIR:"
for i in "${!MODELS[@]}"; do
    model="${MODELS[$i]}"
    marker=""
    if [ "$model" = "$CURRENT_MODEL" ]; then
        marker=" ${GREEN}(current)${NC}"
    fi
    
    # Show model size
    size=$(du -h "${MODELS_DIR}/${model}" | cut -f1)
    printf "  %2d) %-40s [%s]%b\n" "$i" "$model" "$size" "$marker"
done
echo "  q) quit"

# --- Model selection ---
read -rp $'\nChoose model index: ' CHOICE

if [[ "$CHOICE" == "q" ]]; then
    log "Operation cancelled"
    exit 0
fi

if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -lt 0 ] || [ "$CHOICE" -ge "${#MODELS[@]}" ]; then
    die "Invalid selection: $CHOICE"
fi

NEW_MODEL="${MODELS[$CHOICE]}"
NEW_TARGET="${MODELS_DIR}/${NEW_MODEL}"

if [ ! -f "$NEW_TARGET" ]; then
    die "Selected model file not found: $NEW_TARGET"
fi

# Skip if already current
if [ "$NEW_MODEL" = "$CURRENT_MODEL" ]; then
    success "Model '$NEW_MODEL' is already loaded"
    exit 0
fi

# --- Backup current symlink for rollback ---
ROLLBACK_TARGET=""
if [ -L "$SYMLINK" ]; then
    # Create backup of current symlink
    cp -P "$SYMLINK" "$BACKUP_SYMLINK" 2>/dev/null || true
    ROLLBACK_TARGET=$(readlink "$SYMLINK" 2>/dev/null || true)
    log "Backed up current symlink for potential rollback"
fi

# --- Switch model (using relative path for container compatibility) ---
log "Switching to model: $NEW_MODEL"

# Create symlink atomically using relative path
TMP_LINK="${SYMLINK}.tmp.$$"
ln -sfn "$NEW_MODEL" "$TMP_LINK"  # Use relative path
if ! mv "$TMP_LINK" "$SYMLINK"; then
    rm -f "$TMP_LINK"
    die "Failed to update symlink"
fi

success "Symlink updated to point to $NEW_MODEL"

# Store selection history
echo "$NEW_MODEL" > "${MODELS_DIR}/.last_selected_model" 2>/dev/null || true
if [ -n "$CURRENT_MODEL" ]; then
    echo "$CURRENT_MODEL" > "${MODELS_DIR}/.previous_model" 2>/dev/null || true
fi

# --- Restart container if running ---
if [ "$CONTAINER_RUNNING" = true ]; then
    log "Restarting container $CONTAINER_NAME..."
    if ! docker restart "$CONTAINER_NAME" >/dev/null 2>&1; then
        die "Failed to restart container $CONTAINER_NAME"
    fi
    success "Container restarted"
else
    warn "Container not running. Please start it manually:"
    warn "  docker compose up -d"
    exit 0
fi

# --- Health check with progress ---
log "Waiting for model to load (timeout: ${MAX_WAIT}s)..."
echo -n "Health check"

elapsed=0
health_ok=false

while [ $elapsed -lt $MAX_WAIT ]; do
    if curl -sSf --max-time 5 "$HEALTH_URL" >/dev/null 2>&1; then
        health_ok=true
        break
    fi
    printf "."
    sleep $SLEEP
    elapsed=$((elapsed + SLEEP))
done

echo # New line after dots

if [ "$health_ok" = true ]; then
    success "Model successfully loaded: $NEW_MODEL"
    success "Server is healthy and responding"
    
    # Clean up backup on success
    rm -f "$BACKUP_SYMLINK"
    
    # Show some useful info
    echo
    log "Model switch completed successfully!"
    log "Server URL: http://localhost:8080"
    log "Models endpoint: $HEALTH_URL"
    exit 0
fi

# --- Health check failed - attempt rollback ---
echo
error "Health check failed after ${MAX_WAIT}s"

if [ -f "$BACKUP_SYMLINK" ] && [ -n "$ROLLBACK_TARGET" ]; then
    warn "Attempting rollback to previous model..."
    
    # Restore backup symlink
    if cp -P "$BACKUP_SYMLINK" "$SYMLINK" 2>/dev/null; then
        success "Reverted symlink to previous model"
        rm -f "$BACKUP_SYMLINK"
        
        log "Restarting container for rollback..."
        docker restart "$CONTAINER_NAME" >/dev/null 2>&1 || true
        
        # Brief wait to see if rollback works
        sleep 5
        if curl -sSf --max-time 5 "$HEALTH_URL" >/dev/null 2>&1; then
            success "Rollback successful - previous model restored"
        else
            warn "Rollback may not have fully succeeded"
        fi
    else
        error "Failed to restore backup symlink"
    fi
else
    warn "No rollback available (no previous model backup)"
fi

echo
error "Model switch failed. Container logs (last $LOG_LINES lines):"
echo "----------------------------------------"
docker logs --tail "$LOG_LINES" "$CONTAINER_NAME" 2>/dev/null || true
echo "----------------------------------------"
echo

error "Troubleshooting steps:"
error "1. Check if the model file is corrupted"
error "2. Verify model format is compatible with llama.cpp"
error "3. Check available system memory (model may be too large)"
error "4. Review full container logs: docker logs $CONTAINER_NAME"

exit 1
