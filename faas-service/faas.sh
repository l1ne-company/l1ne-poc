#!/bin/bash

# FAAS Service Management Script
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default values
DEFAULT_PORT=8080
DEFAULT_INSTANCE_ID=0

# Functions
print_help() {
    echo "FAAS Service Manager"
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  build       Build the service (debug and release)"
    echo "  run         Run the service"
    echo "  dev         Run in development mode (build + run debug)"
    echo "  test        Run tests"
    echo "  clean       Clean build artifacts"
    echo "  status      Check if service is running"
    echo ""
    echo "Options for 'run' and 'dev':"
    echo "  PORT=<port>            Set port (default: 8080)"
    echo "  INSTANCE_ID=<id>       Set instance ID (default: 0)"
    echo ""
    echo "Examples:"
    echo "  $0 build"
    echo "  $0 run"
    echo "  PORT=8081 INSTANCE_ID=1 $0 run"
    echo "  $0 dev"
}

build_service() {
    echo -e "${GREEN}Building FAAS Service...${NC}"
    
    # Build debug
    echo "Building debug version..."
    cargo build
    
    # Build release
    echo "Building release version..."
    cargo build --release
    
    echo -e "${GREEN}✓ Build complete!${NC}"
    echo "Binaries available at:"
    echo "  - target/debug/faas-service"
    echo "  - target/release/faas-service"
}

run_service() {
    PORT=${PORT:-$DEFAULT_PORT}
    INSTANCE_ID=${INSTANCE_ID:-$DEFAULT_INSTANCE_ID}
    
    echo -e "${GREEN}Starting FAAS Service...${NC}"
    echo "  Port: $PORT"
    echo "  Instance ID: $INSTANCE_ID"
    
    # Export environment variables
    export PORT=$PORT
    export INSTANCE_ID=$INSTANCE_ID
    
    # Determine which binary to run
    if [ "$1" == "release" ] && [ -f "target/release/faas-service" ]; then
        echo "Running release build..."
        exec ./target/release/faas-service
    elif [ -f "target/debug/faas-service" ]; then
        echo "Running debug build..."
        exec ./target/debug/faas-service
    else
        echo -e "${YELLOW}No build found. Building now...${NC}"
        cargo build
        exec ./target/debug/faas-service
    fi
}

dev_mode() {
    echo -e "${GREEN}Starting in development mode...${NC}"
    
    # Build first
    cargo build
    
    # Then run
    PORT=${PORT:-$DEFAULT_PORT}
    INSTANCE_ID=${INSTANCE_ID:-$DEFAULT_INSTANCE_ID}
    
    export PORT=$PORT
    export INSTANCE_ID=$INSTANCE_ID
    
    echo -e "${GREEN}Running service on port $PORT${NC}"
    cargo run --bin faas-service
}

run_tests() {
    echo -e "${GREEN}Running tests...${NC}"
    cargo test
    echo -e "${GREEN}✓ All tests passed!${NC}"
}

clean_build() {
    echo -e "${YELLOW}Cleaning build artifacts...${NC}"
    cargo clean
    echo -e "${GREEN}✓ Clean complete!${NC}"
}

check_status() {
    PORT=${PORT:-$DEFAULT_PORT}
    
    echo "Checking service status on port $PORT..."
    
    if curl -s -f "http://localhost:$PORT/health" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Service is running on port $PORT${NC}"
        echo ""
        echo "Health check response:"
        curl -s "http://localhost:$PORT/health" | jq '.' 2>/dev/null || curl -s "http://localhost:$PORT/health"
    else
        echo -e "${RED}✗ Service is not running on port $PORT${NC}"
        exit 1
    fi
}

# Main command handler
case "$1" in
    build)
        build_service
        ;;
    run)
        run_service "release"
        ;;
    dev)
        dev_mode
        ;;
    test)
        run_tests
        ;;
    clean)
        clean_build
        ;;
    status)
        check_status
        ;;
    help|--help|-h)
        print_help
        ;;
    "")
        echo -e "${YELLOW}No command specified${NC}"
        print_help
        exit 1
        ;;
    *)
        echo -e "${RED}Unknown command: $1${NC}"
        print_help
        exit 1
        ;;
esac