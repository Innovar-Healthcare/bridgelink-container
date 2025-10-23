#!/bin/bash

# URL of the .tar.gz file
URL="https://innovar-oss-mirth-mirror.s3.us-east-2.amazonaws.com/mirth-arch/BridgeLink-4.6.0/BridgeLink_unix_4_6_0.tar.gz"

# Destination folder path
DESTINATION_FOLDER="/opt"

# Name of the downloaded file
FILE_NAME="BridgeLink_unix_4_6_0.tar.gz"

# Log file for debugging
LOG_FILE="/opt/scripts/download_and_extract.log"

# Start logging
echo "Starting download and extract script" | tee -a "$LOG_FILE"
echo "URL: $URL" | tee -a "$LOG_FILE"
echo "Destination: $DESTINATION_FOLDER" | tee -a "$LOG_FILE"

# Download the file with a timeout
echo "Downloading file..." | tee -a "$LOG_FILE"
curl -L --max-time 10000 -o "$FILE_NAME" "$URL" 2>&1 | tee -a "$LOG_FILE"
if [ $? -ne 0 ]; then
  echo "Download failed or timed out" | tee -a "$LOG_FILE"
  exit 1
fi

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