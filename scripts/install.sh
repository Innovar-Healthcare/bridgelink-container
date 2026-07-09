#!/bin/bash

# Fail a pipeline on the first failing command, not just the last. Without this, `curl ... | tee`
# and `tar ... | tee` report tee's exit status (~always 0), which silently defeated the download
# retry loop and the extraction-failure check below (IRT-1387). NOT using `set -e` (it would abort
# the retry loop on the first failed download) or `set -u` ($LOG_FILE is referenced before it is set).
set -o pipefail

# BINARY_URL must be provided at build time via --build-arg
# Supports both s3:// (uses aws s3 cp) and https:// (uses curl)
if [ -z "$BINARY_URL" ]; then
  echo "ERROR: BINARY_URL build arg is not set" | tee -a "$LOG_FILE"
  exit 1
fi

# Destination folder path
DESTINATION_FOLDER="/opt"

# Name of the downloaded file
FILE_NAME="BridgeLink_unix_26_3_1.tar.gz"

# Log file for debugging
LOG_FILE="/opt/scripts/download_and_extract.log"

# Start logging
echo "Starting download and extract script" | tee -a "$LOG_FILE"
echo "Destination: $DESTINATION_FOLDER" | tee -a "$LOG_FILE"

# Download the binary with retry
echo "Downloading binary..." | tee -a "$LOG_FILE"
MAX_RETRIES=5
RETRY_DELAY=10
for i in $(seq 1 $MAX_RETRIES); do
  if [[ "$BINARY_URL" == s3://* ]]; then
    aws s3 cp "$BINARY_URL" "$FILE_NAME" 2>&1 | tee -a "$LOG_FILE"
  else
    curl -L --max-time 10000 -o "$FILE_NAME" "$BINARY_URL" 2>&1 | tee -a "$LOG_FILE"
  fi
  # With pipefail set, $? here reflects curl/aws (the failing side of the pipe), not tee.
  [ $? -eq 0 ] && break
  if [ $i -eq $MAX_RETRIES ]; then
    echo "Download failed after $MAX_RETRIES attempts" | tee -a "$LOG_FILE"
    exit 1
  fi
  echo "Download attempt $i failed, retrying in ${RETRY_DELAY}s..." | tee -a "$LOG_FILE"
  sleep $RETRY_DELAY
done

# Create the destination folder if it doesn't exist
echo "Creating destination folder..." | tee -a "$LOG_FILE"
mkdir -p "$DESTINATION_FOLDER"

# Extract the downloaded file to the destination folder
echo "Extracting file..." | tee -a "$LOG_FILE"
tar -xzvf "$FILE_NAME" -C "$DESTINATION_FOLDER" 2>&1 | tee -a "$LOG_FILE"
if [ $? -ne 0 ]; then
  echo "Extraction failed" | tee -a "$LOG_FILE"
  exit 1
fi

# Rename the extracted folder to "connect"
echo "Renaming folder to 'bridgelink'..." | tee -a "$LOG_FILE"
mv "$DESTINATION_FOLDER/BridgeLink" "$DESTINATION_FOLDER/bridgelink"
if [ $? -ne 0 ]; then
  echo "Rename failed" | tee -a "$LOG_FILE"
  rm -rf "$TEMP_DIR"
  exit 1
fi

# Optionally, remove the downloaded .tar.gz file
echo "Cleaning up..." | tee -a "$LOG_FILE"
rm "$FILE_NAME"

echo "Download and extraction complete!" | tee -a "$LOG_FILE"