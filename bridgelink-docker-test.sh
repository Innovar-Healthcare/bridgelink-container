#!/bin/bash
set -e  # Exit immediately if a command exits with a non-zero status

# Create image name tag bridgelink-container:latest
docker build --no-cache -t bridgelink-container:latest .

# Run docker compose, create bridgelink and postgres db, the files is docker-composed.yml
docker compose up
