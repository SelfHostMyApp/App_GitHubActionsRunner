#!/bin/bash
# setup.sh - Build and prepare the Puppet Master architecture
#
# Usage:
#   ./setup.sh          # Build images
#   ./setup.sh start    # Build and start
#   ./setup.sh stop     # Stop puppet master
#   ./setup.sh logs     # View logs
#   ./setup.sh status   # Show running containers

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_prerequisites() {
    log_info "Checking prerequisites..."

    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed"
        exit 1
    fi

    if ! docker info &> /dev/null; then
        log_error "Docker daemon is not running or not accessible"
        exit 1
    fi

    if [ ! -f ".env" ]; then
        if [ -f ".env.example" ]; then
            log_warn ".env file not found. Creating from .env.example"
            cp .env.example .env
            log_warn "Please edit .env and set your GITHUB_PAT"
            exit 1
        else
            log_error ".env file not found and no .env.example to copy"
            exit 1
        fi
    fi

    if [ ! -f "count.json" ]; then
        if [ -f "count.json.example" ]; then
            log_warn "count.json not found. Creating from count.json.example"
            cp count.json.example count.json
            log_warn "Please edit count.json with your repositories"
            exit 1
        else
            log_error "count.json not found"
            exit 1
        fi
    fi

    log_info "Prerequisites OK"
}

build_images() {
    log_info "Building ephemeral runner image..."
    docker build -t gh-ephemeral-runner:latest -f Dockerfile.ephemeral-runner .

    log_info "Building puppet master image..."
    docker build -t gh-puppet-master:latest -f Dockerfile.puppet-master .

    log_info "Images built successfully"
}

start() {
    check_prerequisites
    build_images

    log_info "Starting puppet master..."
    docker-compose up -d puppet-master

    log_info "Puppet master started!"
    echo ""
    log_info "View logs with: ./setup.sh logs"
    log_info "Check status with: ./setup.sh status"
}

stop() {
    log_info "Stopping puppet master..."
    docker-compose down

    # Also stop any orphaned ephemeral runners
    log_info "Stopping any orphaned ephemeral runners..."
    docker ps --filter "name=ephemeral-runner" -q | xargs -r docker stop 2>/dev/null || true
    docker ps -a --filter "name=ephemeral-runner" -q | xargs -r docker rm 2>/dev/null || true

    log_info "Stopped"
}

logs() {
    docker-compose logs -f puppet-master
}

status() {
    echo ""
    log_info "Puppet Master Status:"
    docker ps --filter "name=gh-puppet-master" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"

    echo ""
    log_info "Ephemeral Runners:"
    docker ps --filter "name=ephemeral-runner" --format "table {{.Names}}\t{{.Status}}\t{{.RunningFor}}"

    echo ""
    log_info "Exited Runners (pending cleanup):"
    docker ps -a --filter "name=ephemeral-runner" --filter "status=exited" --format "table {{.Names}}\t{{.Status}}"
}

case "${1:-build}" in
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
    *)
        echo "Usage: $0 {build|start|stop|logs|status}"
        exit 1
        ;;
esac
