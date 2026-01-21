#!/bin/bash
# Quick test script for branding development
# This script builds and runs the branding in development mode

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRANDING_SOURCE="${1:-../../la-test-branding}"

echo "🚀 Quick Start - Branding Development Mode"
echo ""
echo "This will:"
echo "  1. Build the branding image (development target)"
echo "  2. Run it with hot-reload enabled"
echo "  3. Mount source directory as volume"
echo ""
echo "Source: $BRANDING_SOURCE"
echo ""
read -p "Press Enter to continue or Ctrl+C to cancel..."

# Build and run in development mode
"$SCRIPT_DIR/build-branding.sh" "$BRANDING_SOURCE" --dev --test
