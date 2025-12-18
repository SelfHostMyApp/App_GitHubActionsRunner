#!/bin/sh
set -e

# GitHub Actions Runner Admin Setup Script
# This script handles admin-level setup tasks (run as root by services.sh)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GH_ACTIONS_VOLUMES="/srv/gh-actions"

printf "=== GitHub Actions Runner Admin Setup ===\n"

# Create service volume directories
printf "Creating GitHub Actions Runner volume directories...\n"
mkdir -p "${GH_ACTIONS_VOLUMES}/actions-runner"
mkdir -p "${GH_ACTIONS_VOLUMES}/work"

# Set ownership to podman user
printf "Setting ownership to podman user...\n"
chown -R podman:podman "$GH_ACTIONS_VOLUMES"

# Set base permissions
printf "Setting permissions for GitHub Actions Runner directories...\n"
chmod -R 755 "$GH_ACTIONS_VOLUMES"

# Set up ACL permissions for podman user access
printf "Setting ACL permissions for podman user...\n"
if command -v setfacl >/dev/null 2>&1; then
    # Grant podman user full access recursively
    setfacl -R -m u:podman:rwx "$GH_ACTIONS_VOLUMES"
    setfacl -R -m m::rwx "$GH_ACTIONS_VOLUMES"
    # Set default ACL for new files/directories
    setfacl -R -d -m u:podman:rwx "$GH_ACTIONS_VOLUMES"
    setfacl -R -d -m m::rwx "$GH_ACTIONS_VOLUMES"
    printf "ACL permissions set for podman user\n"
else
    printf "Warning: setfacl not available, using chmod only\n"
fi

# No firewall configuration needed for GitHub Actions Runner (outbound connections only)
printf "Note: GitHub Actions Runner uses outbound connections only - no firewall ports needed\n"

printf "GitHub Actions Runner admin setup complete\n"