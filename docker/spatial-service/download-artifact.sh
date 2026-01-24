#!/bin/bash
set -e

# ANSI colors
BLUE='\033[1;34m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
CYAN='\033[1;36m'
NC='\033[0m' # No Color

# Helper for formatted output
log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }
log_action() { echo -e "${CYAN}🚀 $1${NC}"; }
log_detail() { echo -e "   $1"; }

build_nexus() {
    # Validate required variables
    if [ -z "${ARTIFACT}" ] || [ -z "${VERSION}" ]; then
        log_error "ARTIFACT and VERSION must be set for nexus build method"
        exit 1
    fi

    # Construct artifact name and URL
    local artifact_name="${ARTIFACT}-${VERSION}${CLASSIFIER:+-${CLASSIFIER}}"
    local full_artifact_name="${artifact_name}.war"
    local nexus_base_url="https://nexus.ala.org.au/repository/releases"
    local nexus_url="${nexus_base_url}/au/org/ala/${ARTIFACT}/${VERSION}/${full_artifact_name}"
    local cache_dir="/cache/nexus"
    local cache_file="${cache_dir}/${full_artifact_name}"

    log_action "Processing Artifact: ${full_artifact_name}"

    # Check cache
    if [ -f "${cache_file}" ]; then
        echo -e "${GREEN}📥 Cache Hit:${NC} Using cached file from ${cache_file}"
        cp "${cache_file}" artifact.war
    else
        echo -e "${YELLOW}⬇️  Cache Miss:${NC} Downloading from Nexus..."
        log_detail "Source: ${nexus_url}"
        
        # Download with curl (fail fast, follow redirects, silent but show errors)
        if curl -sSL -f -o artifact.war "${nexus_url}"; then
            echo -e "${GREEN}💾 Caching:${NC} Saving to ${cache_file}"
            mkdir -p "${cache_dir}"
            cp artifact.war "${cache_file}"
        else
            log_error "Download failed!"
            exit 1
        fi
    fi
}

build_url() {
    if [ -z "${ARTIFACT_URL}" ]; then
        log_error "ARTIFACT_URL must be specified for url build method"
        exit 1
    fi

    log_action "Downloading from URL"
    log_detail "URL: ${ARTIFACT_URL}"
    
    echo -e "${YELLOW}⬇️  Downloading...${NC}"
    if curl -sSL -f -o artifact.war "${ARTIFACT_URL}"; then
        log_success "Download complete"
    else
        log_error "Download failed!"
        exit 1
    fi
}

# Main logic
if [ "${BUILD_METHOD}" = "url" ]; then
    build_url
else
    # Default to nexus
    build_nexus
fi

# Print final stats
if [ -f "artifact.war" ]; then
    size=$(ls -lh artifact.war | awk '{print $5}')
    echo -e "${CYAN}📊 Artifact Size:${NC} ${size}"
    log_success "Artifact ready!"
else
    log_error "artifact.war not found after build step!"
    exit 1
fi
