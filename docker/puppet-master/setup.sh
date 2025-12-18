#!/bin/bash
# setup.sh - Build and prepare the Puppet Master architecture
#
# Supports both Docker and Podman runtimes
#
# Usage:
#   ./setup.sh          # Show help
#   ./setup.sh start    # Build and start
#   ./setup.sh stop     # Stop puppet master
#   ./setup.sh logs     # View logs
#   ./setup.sh status   # Show running containers

# Don't use set -e so we can show errors properly
# set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Trap errors and show them
trap 'echo ""; echo "ERROR: Script failed at line $LINENO. Exit code: $?"; read -p "Press Enter to exit..."' ERR

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Exit with error, pausing so user can see message
die() {
    log_error "$1"
    echo ""
    read -p "Press Enter to exit..."
    exit 1
}

# Detect container runtime
detect_runtime() {
    if command -v docker &> /dev/null && docker info &> /dev/null 2>&1; then
        echo "docker"
    elif command -v podman &> /dev/null && podman info &> /dev/null 2>&1; then
        echo "podman"
    else
        echo ""
    fi
}

# Detect compose command
detect_compose() {
    local runtime="$1"
    if [ "$runtime" = "docker" ]; then
        if docker compose version &> /dev/null 2>&1; then
            echo "docker compose"
        elif command -v docker-compose &> /dev/null; then
            echo "docker-compose"
        else
            echo ""
        fi
    elif [ "$runtime" = "podman" ]; then
        if command -v podman-compose &> /dev/null; then
            echo "podman-compose"
        else
            echo ""
        fi
    fi
}

# Detect socket path
detect_socket() {
    if [ -e "/var/run/docker.sock" ]; then
        echo "/var/run/docker.sock"
    elif [ -e "/var/run/podman/podman.sock" ]; then
        echo "/var/run/podman/podman.sock"
    elif [ -e "/run/podman/podman.sock" ]; then
        echo "/run/podman/podman.sock"
    elif [ -n "$XDG_RUNTIME_DIR" ] && [ -e "$XDG_RUNTIME_DIR/podman/podman.sock" ]; then
        echo "$XDG_RUNTIME_DIR/podman/podman.sock"
    else
        echo ""
    fi
}

RUNTIME=$(detect_runtime)
COMPOSE=$(detect_compose "$RUNTIME")
SOCKET=$(detect_socket)

check_prerequisites() {
    log_step "Checking prerequisites..."

    if [ -z "$RUNTIME" ]; then
        die "Neither Docker nor Podman is available or running"
    fi
    log_info "Container runtime: $RUNTIME"

    if [ -z "$SOCKET" ]; then
        log_warn "Could not detect container socket path"
        log_warn "Make sure your container runtime is running"
    else
        log_info "Socket path: $SOCKET"
    fi

    if [ -z "$COMPOSE" ]; then
        log_warn "No compose tool found. Will use direct $RUNTIME commands."
    else
        log_info "Compose tool: $COMPOSE"
    fi

    if [ ! -f ".env" ]; then
        if [ -f ".env.example" ]; then
            log_warn ".env file not found. Creating from .env.example"
            cp .env.example .env
            die "Please edit .env and set your GITHUB_PAT, then run again"
        else
            die ".env file not found and no .env.example to copy"
        fi
    fi

    # Source .env to check GITHUB_PAT
    source .env
    if [ -z "$GITHUB_PAT" ] || [ "$GITHUB_PAT" = "ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ]; then
        die "GITHUB_PAT not set in .env file"
    fi

    if [ ! -f "config.json" ]; then
        if [ -f "config.json.example" ]; then
            log_warn "config.json not found. Creating from config.json.example"
            cp config.json.example config.json
            die "Please edit config.json with your repositories/organizations, then run again"
        else
            die "config.json not found"
        fi
    fi

    log_info "Prerequisites OK"
    echo ""
}

build_images() {
    log_step "Building container images..."

    log_info "Building ephemeral runner image..."
    $RUNTIME build -t gh-ephemeral-runner:latest -f Dockerfile.ephemeral-runner .

    log_info "Building puppet master image..."
    $RUNTIME build -t gh-puppet-master:latest -f Dockerfile.puppet-master .

    log_info "Images built successfully"
    echo ""
}

start_with_compose() {
    log_step "Starting puppet master with $COMPOSE..."

    # Create network if needed (marked as external in compose file)
    $RUNTIME network inspect github-runners >/dev/null 2>&1 || {
        log_info "Creating network: github-runners"
        $RUNTIME network create github-runners
    }

    $COMPOSE up -d puppet-master
}

start_without_compose() {
    log_step "Starting puppet master with $RUNTIME..."

    # Source environment
    source .env

    # Create network if needed
    $RUNTIME network inspect github-runners >/dev/null 2>&1 || {
        log_info "Creating network: github-runners"
        $RUNTIME network create github-runners
    }

    # Stop existing container if running
    $RUNTIME stop gh-puppet-master 2>/dev/null || true
    $RUNTIME rm gh-puppet-master 2>/dev/null || true

    # Determine socket mount
    local socket_mount=""
    if [ -n "$SOCKET" ]; then
        socket_mount="-v ${SOCKET}:/var/run/docker.sock"
    fi

    # Start the puppet master
    $RUNTIME run -d \
        --name gh-puppet-master \
        --network github-runners \
        --restart unless-stopped \
        $socket_mount \
        -v "$(pwd)/config.json:/config/config.json:ro" \
        -e GITHUB_PAT="$GITHUB_PAT" \
        -e POLL_INTERVAL="${POLL_INTERVAL:-30}" \
        -e RUNNER_IMAGE="${RUNNER_IMAGE:-gh-ephemeral-runner:latest}" \
        -e CONTAINER_NETWORK="${CONTAINER_NETWORK:-github-runners}" \
        gh-puppet-master:latest
}

start() {
    check_prerequisites
    build_images

    if [ -n "$COMPOSE" ]; then
        start_with_compose
    else
        start_without_compose
    fi

    log_info "Puppet master started!"
    echo ""
    log_info "View logs with: ./setup.sh logs"
    log_info "Check status with: ./setup.sh status"
}

stop() {
    log_step "Stopping puppet master..."

    if [ -n "$COMPOSE" ]; then
        $COMPOSE down 2>/dev/null || true
    fi

    $RUNTIME stop gh-puppet-master 2>/dev/null || true
    $RUNTIME rm gh-puppet-master 2>/dev/null || true

    # Also stop any orphaned ephemeral runners
    log_info "Stopping any orphaned ephemeral runners..."
    $RUNTIME ps --filter "name=eph-" -q 2>/dev/null | xargs -r $RUNTIME stop 2>/dev/null || true
    $RUNTIME ps -a --filter "name=eph-" -q 2>/dev/null | xargs -r $RUNTIME rm 2>/dev/null || true

    log_info "Stopped"
}

logs() {
    if [ -n "$COMPOSE" ]; then
        $COMPOSE logs -f puppet-master
    else
        $RUNTIME logs -f gh-puppet-master
    fi
}

status() {
    echo ""
    log_info "Container Runtime: $RUNTIME"
    echo ""

    log_info "Puppet Master Status:"
    $RUNTIME ps --filter "name=gh-puppet-master" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" 2>/dev/null || \
        $RUNTIME ps --filter "name=gh-puppet-master"

    echo ""
    log_info "Active Ephemeral Runners:"
    $RUNTIME ps --filter "name=eph-" --format "table {{.Names}}\t{{.Status}}\t{{.RunningFor}}" 2>/dev/null || \
        $RUNTIME ps --filter "name=eph-"

    echo ""
    log_info "Exited Runners (pending cleanup):"
    $RUNTIME ps -a --filter "name=eph-" --filter "status=exited" --format "table {{.Names}}\t{{.Status}}" 2>/dev/null || \
        $RUNTIME ps -a --filter "name=eph-" --filter "status=exited"

    echo ""
    log_info "Config Summary:"
    if [ -f "config.json" ]; then
        echo "  Repos configured: $(jq -r '.repos // {} | keys | length' config.json)"
        echo "  Orgs configured: $(jq -r '.orgs // {} | keys | length' config.json)"
    else
        echo "  config.json not found"
    fi
}

print_usage() {
    echo "Usage: $0 {build|start|stop|logs|status}"
    echo ""
    echo "Commands:"
    echo "  build   - Build container images"
    echo "  start   - Build images and start puppet master"
    echo "  stop    - Stop puppet master and cleanup runners"
    echo "  logs    - View puppet master logs (follow mode)"
    echo "  status  - Show status of all runner containers"
    echo ""
    echo "Detected runtime: ${RUNTIME:-none}"
    echo "Detected compose: ${COMPOSE:-none}"
}

case "${1:-help}" in
    build)
        check_prerequisites
        build_images
        ;;
    start)
        start
        ;;
    stop)
        stop
        ;;
    logs)
        logs
        ;;
    status)
        status
        ;;
    help|--help|-h)
        print_usage
        ;;
    *)
        log_error "Unknown command: $1"
        print_usage
        echo ""
        read -p "Press Enter to exit..."
        exit 1
        ;;
esac

# Pause at end so output is visible if launched from file manager
echo ""
read -p "Press Enter to close..."
