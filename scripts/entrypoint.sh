#!/bin/bash

# Files to be modified
PROPERTIES_FILE="/opt/bridgelink/conf/mirth.properties"
VMOPTIONS_FILE="/opt/bridgelink/blserver.vmoptions"
SERVER_ID_FILE="/opt/bridgelink/appdata/server.id"
KEYSTORE_FILE="/opt/bridgelink/appdata/keystore.jks"
EXTENSIONS_DIR="/opt/bridgelink/extensions"
CUSTOM_JARS_DIR="/opt/bridgelink/custom-jars"
S3_CUSTOM_JARS_DIR="/opt/bridgelink/S3_custom-jars"
APPDATA_DIR="/opt/bridgelink/appdata"

# Function to update a property in the file
update_property() {
  local file=$1
  local property=$2
  local value=$3
  if [ ! -z "$value" ]; then
    # Escape special characters
    value_escaped=$(sed 's/[\/&]/\\&/g' <<<"$value")
    # Check if the property is 'vmoptions' for updating the -Xmx value
    if [[ "$property" == "vmoptions" ]]; then
      # Append 'm' to the value (e.g., 256 becomes 256m)
      value_escaped="${value_escaped}m"
      # Use sed to update the -Xmx line in the VM options file
      if grep -q "^[-]Xmx[0-9]*[kKmMgG]" "$file"; then
        sed -i "s|^-Xmx[0-9]*[kKmMgG]|-Xmx${value_escaped}|" "$file"
      else
        echo "-Xmx${value_escaped}" >> "$file"
      fi
    else
      # Handle other properties as usual
      if grep -q "^${property} =" "$file"; then
        sed -i "s|^${property} =.*|${property} = ${value_escaped}|" "$file"
      else
        echo "${property} = ${value_escaped}" >>"$file"
      fi
    fi
  fi
}

apply_mp_vmoptions() {
  IFS=',' read -ra OPTIONS <<< "$MP_VMOPTIONS"

  sed -i -e '$a\' "$VMOPTIONS_FILE"
  for raw_opt in "${OPTIONS[@]}"; do
    opt=$(echo "$raw_opt" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    opt=$(echo "$opt" | sed -E 's/[[:space:]]*=[[:space:]]*/=/g')

    if [[ "$opt" =~ ^[0-9]+$ ]]; then
      update_property "$VMOPTIONS_FILE" "vmoptions" "$opt"
    else
      # Quote the string to handle odd characters safely
      if ! grep -Fxq -- "$opt" "$VMOPTIONS_FILE"; then
        echo "$opt" >> "$VMOPTIONS_FILE"
      fi
    fi
  done
  sed -i -e '$a\' "$VMOPTIONS_FILE"
}

# Check and write SERVER_ID to the specified file
if [ ! -z "$SERVER_ID" ]; then
  echo -e "server.id = ${SERVER_ID//\//\\/}" > "$SERVER_ID_FILE"
fi


# Check if CUSTOM_VMOPTIONS environment variable is set and not empty
if [[ -n "$CUSTOM_VMOPTIONS" ]]; then
    echo "Downloading custom vmoptions from: $CUSTOM_VMOPTIONS"

    # Create directory if it doesn't exist
    mkdir -p "$(dirname "$VMOPTIONS_FILE")"

    CURL_OPTS="-sSLf"
    [ "${ALLOW_INSECURE}" = "true" ] && CURL_OPTS="-ksSLf"

    # Download and overwrite the target file
    curl --silent --show-error ${CURL_OPTS} "$CUSTOM_VMOPTIONS" -o "$VMOPTIONS_FILE"

    # Check if download succeeded
    if [[ $? -eq 0 ]]; then
        echo "Successfully downloaded and saved to $VMOPTIONS_FILE"
    else
        echo "Failed to download the vmoptions from $CUSTOM_VMOPTIONS"
        exit 1
    fi
else
    echo "CUSTOM_VMOPTIONS is not set. Skipping vmoptions download."
fi

# Check if CUSTOM_PROPERTIES environment variable is set and not empty
if [[ -n "$CUSTOM_PROPERTIES" ]]; then
    echo "Downloading custom mirth.properties from: $CUSTOM_PROPERTIES"

    # Create target directory if it doesn't exist
    mkdir -p "$(dirname "$PROPERTIES_FILE")"

    CURL_OPTS="-sSLf"
    [ "${ALLOW_INSECURE}" = "true" ] && CURL_OPTS="-ksSLf"

    # Download the file and overwrite the target
    curl --silent --show-error ${CURL_OPTS} "$CUSTOM_PROPERTIES" -o "$PROPERTIES_FILE"

    # Verify download success
    if [[ $? -eq 0 ]]; then
        echo "Successfully downloaded and saved to $PROPERTIES_FILE"
    else
        echo "Failed to download from $CUSTOM_PROPERTIES"
        exit 1
    fi
else
    echo "CUSTOM_PROPERTIES is not set. Skipping mirth.properties download."
fi


# Loop over environment variables with prefix MP_
for var in $(env | grep '^MP_' | sed 's/=.*//'); do
  value=${!var}                                # Extract the value of the variable
  var_without_prefix=${var#MP_}                # Remove the MP_ prefix


  # Handle custom mapping logic for specific variables using if statement
  if [ "$var_without_prefix" == "DATABASE_RETRY_WAIT" ]; then
    # Overwrite the environment variable with the new name
    export DATABASE_CONNECTION_RETRYWAITINMILLISECONDS="$value"
    var_without_prefix="DATABASE_CONNECTION_RETRYWAITINMILLISECONDS"
  
  fi
  # Replace double underscores with dashes and single underscores with dots
  property=$(echo "$var_without_prefix" | tr '[:upper:]' '[:lower:]' | sed 's/__/-/g; s/_/./g')


  # Choose file to update
  if [ "$var_without_prefix" == "VMOPTIONS" ]; then
    apply_mp_vmoptions
  else
    update_property "$PROPERTIES_FILE" "$property" "$value"
  fi
done


# # Download and extract extensions if EXTENSIONS_DOWNLOAD is set
if [ -n "${EXTENSIONS_DOWNLOAD}" ]; then
  echo "Downloading extensions from ${EXTENSIONS_DOWNLOAD}"
  cd ${EXTENSIONS_DIR}

  CURL_OPTS="-sSLf"
  [ "${ALLOW_INSECURE}" = "true" ] && CURL_OPTS="-ksSLf"

  # Split URLs by space and iterate over them
  IFS=',' read -r -a urls <<< "${EXTENSIONS_DOWNLOAD}"
  for url in "${urls[@]}"; do
    echo "Downloading from ${url}"
    # Extract filename from URL
    filename=$(basename "$url")
    curl ${CURL_OPTS} "${url}" -o "$filename" || { echo "Problem with extensions download from ${url}"; continue; }

    echo "Extracting contents of $filename"

    jar xf "$filename" || { echo "Problem extracting contents of $filename"; continue; }
    rm "$filename"
  done
fi

# Download and extract jars if CUSTOM_JARS_DOWNLOAD is set
if [ -n "${CUSTOM_JARS_DOWNLOAD}" ]; then
  echo "Downloading jars from ${CUSTOM_JARS_DOWNLOAD}"

  mkdir ${CUSTOM_JARS_DIR}

  cd ${CUSTOM_JARS_DIR}

  CURL_OPTS="-sSLf"
  [ "${ALLOW_INSECURE}" = "true" ] && CURL_OPTS="-ksSLf"

  # Split URLs by space and iterate over them
  IFS=',' read -r -a urls <<< "${CUSTOM_JARS_DOWNLOAD}"
  for url in "${urls[@]}"; do
    echo "Downloading from ${url}"
    # Extract filename from URL
    filename=$(basename "$url")
    curl ${CURL_OPTS} "${url}" -o "$filename" || { echo "Problem with jars download from ${url}"; continue; }

    jar xf "$filename" || { echo "Problem extracting contents of $filename"; continue; }
    rm "$filename"
  done
fi

# Create the appdata directory if it doesn't exist
mkdir -p "$APPDATA_DIR"

# Only attempt download if the environment variable is set
if [ -n "$KEYSTORE_DOWNLOAD" ]; then
    # Create the appdata directory if it doesn't exist
    mkdir -p "$APPDATA_DIR"

    # Download the keystore file quietly
    echo "Downloading keystore from: $KEYSTORE_DOWNLOAD"
    curl --silent --show-error -fSL "$KEYSTORE_DOWNLOAD" -o "$KEYSTORE_FILE"

    # Check if the download was successful
    if [ $? -eq 0 ]; then
        echo "Keystore successfully downloaded to: $KEYSTORE_FILE"
    else
        echo "Failed to download the keystore."
        exit 1
    fi
else
    echo "KEYSTORE_DOWNLOAD is not set. Skipping keystore download."
fi



# merge the user's secret mirth.properties
# takes a whole mirth.properties file and merges line by line with /opt/bridgelink/conf/mirth.properties
if [ -f /run/secrets/mirth_properties ]; then

    # add new line in case /opt/bridgelinkconf/mirth.properties doesn't end with one
    echo "" >> /opt/bridgelink/conf/mirth.properties
    # Loop through each line in the source properties file
    while IFS='=' read -r key value; do
        # Skip empty lines or comments
        [[ -z "$key" || "$key" == \#* ]] && continue

        # Escape special characters for use in sed
        escaped_key=$(printf '%s\n' "$key" | sed 's/[.[\*^$/]/\\&/g')
        escaped_value=$(printf '%s\n' "$value" | sed 's/[\/&]/\\&/g')

        if grep -q "^$escaped_key\s*=" "$PROPERTIES_FILE"; then
            # Key exists – replace value
            sed -i "s/^$escaped_key\s*=.*/$key = $escaped_value/" "$PROPERTIES_FILE"
        else
            # Key doesn't exist – append to bottom
            echo -e "\n$key = $value" >> "$PROPERTIES_FILE"
        fi
    done < "/run/secrets/mirth_properties"
fi


# merge the user's secret vmoptions
# takes a whole blserver.vmoptions file and merges line by line with /opt/bridgelink/blserver.vmoptions
if [ -f /run/secrets/blserver_vmoptions ]; then
    (cat /run/secrets/blserver_vmoptions ; echo "") >> /opt/bridgelink/blserver.vmoptions
fi

# Enable nullglob so *.zip returns empty if no matches
shopt -s nullglob
zip_files=("/opt/bridgelink/custom-extensions"/*.zip)
shopt -u nullglob

# Check if zip_files array has any files
if [ ${#zip_files[@]} -gt 0 ]; then
  for zip_file in "${zip_files[@]}"; do
    (cd "$EXTENSIONS_DIR" && jar xf "$zip_file")
  done
fi

cd /opt/bridgelink

exec "$@"







