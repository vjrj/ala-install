#!/bin/bash
# Branding Docker Build and Test Script
# Usage: ./build-branding.sh [path-to-branding-source] [options]
#
# Options:
#   --dev       Build for development (with hot-reload)
#   --git URL   Clone from git repository
#   --ref REF   Git branch/tag/commit (default: master)
#   --test      Run test server after build

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRANDING_SOURCE="${1:-../../la-test-branding}"
IMAGE_NAME="${IMAGE_NAME:-branding:latest}"
TARGET="production"
RUN_TEST=false
GIT_URL=""
GIT_REF="master"

# Parse arguments
shift || true
while [[ $# -gt 0 ]]; do
    case $1 in
        --dev)
            TARGET="development"
            shift
            ;;
        --git)
            GIT_URL="$2"
            shift 2
            ;;
        --ref)
            GIT_REF="$2"
            shift 2
            ;;
        --test)
            RUN_TEST=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "🏗️  Building branding Docker image..."
echo "   Target: $TARGET"

# Determine build source
if [ -n "$GIT_URL" ]; then
    echo "   Source: Git repository"
    echo "   URL: $GIT_URL"
    echo "   Ref: $GIT_REF"
    BUILD_SOURCE="git"

    # Create temp directory for git clone
    TEMP_DIR=$(mktemp -d)
    trap "rm -rf $TEMP_DIR" EXIT

    echo ""
    echo "📥 Cloning repository..."
    git clone "$GIT_URL" "$TEMP_DIR"
    cd "$TEMP_DIR"
    git checkout "$GIT_REF"

    # Update submodules if present
    if [ -f .gitmodules ]; then
        echo "📦 Updating git submodules..."
        git submodule update --init --recursive || echo "⚠️  Submodule update failed"
    fi

    BRANDING_SOURCE="$TEMP_DIR"
else
    echo "   Source: Local directory"
    echo "   Path: $BRANDING_SOURCE"
    BUILD_SOURCE="local"

    # Check if branding source exists
    if [ ! -d "$BRANDING_SOURCE" ]; then
        echo "❌ Error: Branding source directory not found: $BRANDING_SOURCE"
        exit 1
    fi

    # Check if package.json exists
    if [ ! -f "$BRANDING_SOURCE/package.json" ]; then
        echo "❌ Error: package.json not found in: $BRANDING_SOURCE"
        exit 1
    fi
fi

echo "   Image: $IMAGE_NAME"
echo ""

# Build the Docker image
docker build \
    -f "$SCRIPT_DIR/Dockerfile" \
    --build-arg BUILD_SOURCE="$BUILD_SOURCE" \
    --build-arg TARGET="$TARGET" \
    $([ -n "$GIT_URL" ] && echo "--build-arg GIT_URL=$GIT_URL --build-arg GIT_REF=$GIT_REF") \
    -t "$IMAGE_NAME" \
    "$BRANDING_SOURCE"

echo ""
echo "✅ Build completed successfully!"
echo ""

if [ "$RUN_TEST" = true ]; then
    echo "🚀 Starting test server..."

    if [ "$TARGET" = "development" ]; then
        PORT=3000
        echo "   Development mode - Hot reload enabled"
        echo "   Mounting source directory as volume"
        docker run --rm -it \
            -p $PORT:3000 \
            -p 5173:5173 \
            -v "$BRANDING_SOURCE:/build:rw" \
            "$IMAGE_NAME"
    else
        PORT=8080
        echo "   Production mode - Serving static files"
        docker run --rm -it \
            -p $PORT:80 \
            "$IMAGE_NAME"
    fi

    echo ""
    echo "🌐 Open http://localhost:$PORT in your browser"
else
    echo "To test the image locally, run:"
    if [ "$TARGET" = "development" ]; then
        echo "  docker run --rm -it -p 3000:3000 -p 5173:5173 -v \"\$(pwd)/$BRANDING_SOURCE:/build:rw\" $IMAGE_NAME"
        echo ""
        echo "Then open http://localhost:3000 (Brunch) or http://localhost:5173 (Vite)"
    else
        echo "  docker run --rm -p 8080:80 $IMAGE_NAME"
        echo ""
        echo "Then open http://localhost:8080 in your browser"
    fi
fi

echo ""
echo "To push the image to a registry:"
echo "  docker push $IMAGE_NAME"
