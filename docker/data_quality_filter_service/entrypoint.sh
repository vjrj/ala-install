#!/bin/bash
# Auto-generated entrypoint for dataQuality
# Provides DEBUG_ENTRYPOINT functionality for troubleshooting
#
# Environment variables:
#   DEBUG_ENTRYPOINT=1    Keep container alive on errors (drops to shell instead of exiting)

SERVICE_USER="dataQuality"
APP_ARTIFACT="data-quality-filter-service"
DEBUG_MODE="${DEBUG_ENTRYPOINT:-0}"

echo "🚀 Starting dataQuality as user: ${SERVICE_USER}"
[ "${DEBUG_MODE}" = "1" ] && echo "   (DEBUG MODE ENABLED)"
echo ""

# Debug: Show environment
if [ "${DEBUG_MODE}" = "1" ] || [ "${DEBUG_MODE}" = "true" ]; then
    echo "📋 Environment variables:"
    echo "   USER=$(id -un)"
    echo "   JAVA_OPTS=${JAVA_OPTS}"
    echo "   LOGGING_CONFIG=${LOGGING_CONFIG:-not set}"
    echo "   LOG_DIR=${LOG_DIR:-not set}"
    echo "   PATH=${PATH}"
    echo ""
    echo "📋 Executing command: $@"
    echo "---"
    echo ""
fi

# Execute the CMD - if it fails in DEBUG mode, drop to shell
if [ "${DEBUG_MODE}" = "1" ] || [ "${DEBUG_MODE}" = "true" ]; then
    # In debug mode, try to run and stay alive if it fails
    "$@"
    EXIT_CODE=$?

    if [ ${EXIT_CODE} -ne 0 ]; then
        echo ""
        echo "❌ Service exited with code: ${EXIT_CODE}"
        echo "🔍 DEBUG MODE ACTIVE - Dropping to shell for investigation..."
        echo "💡 Tip: Use 'exit' to leave the shell"
        echo ""
        /bin/bash
        exit ${EXIT_CODE}
    fi
else
    # Normal mode: just exec and let it fail normally
    exec "$@"
fi

