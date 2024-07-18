#!/bin/bash

# Files to be modified
PROPERTIES_FILE="/opt/connect/conf/mirth.properties"
VMOPTIONS_FILE="/opt/connect/vmoptions.properties"
SERVER_ID_FILE="/opt/connect/appdata/server.id"
EXTENSIONS_DIR="/opt/connect/extensions"
CUSTOM_JARS_DIR="/opt/connect/custom-jars"

# Function to update a property in the file
update_property() {
  local file=$1
  local property=$2
  local value=$3
  if [ ! -z "$value" ]; then
    # Escape special characters
    value_escaped=$(sed 's/[\/&]/\\&/g' <<<"$value")
    if grep -q "^${property} =" "$file"; then
      sed -i "s|^${property} =.*|${property} = ${value_escaped}|" "$file"
    else
      echo "${property} = ${value_escaped}" >>"$file"
    fi
  fi
}

# Check and write SERVER_ID to the specified file
if [ ! -z "$SERVER_ID" ]; then
  echo -e "server.id = ${SERVER_ID//\//\\/}" > "$SERVER_ID_FILE"
fi

# Loop over environment variables with prefix MP_
for var in $(env | grep '^MP_' | sed 's/=.*//'); do
  # Extract the value of the environment variable
  value=${!var}
  
  # Remove the prefix
  var_without_prefix=${var#MP_}
  
  # Replace double underscores with dash and single underscores with dots
  property=$(echo "$var_without_prefix" | tr '[:upper:]' '[:lower:]' | sed 's/__/-/g; s/_/./g')

  # Determine which file to update
  if [ "$var_without_prefix" == "VMOPTIONS" ]; then
    update_property "$VMOPTIONS_FILE" "$property" "$value"
  else
    update_property "$PROPERTIES_FILE" "$property" "$value"
  fi
done

# Download and extract extensions if EXTENSIONS_DOWNLOAD is set
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

# Download and extract extensions if EXTENSIONS_DOWNLOAD is set
if [ -n "${CUSTOM_JARS_DOWNLOAD}" ]; then
  echo "Downloading extensions from ${CUSTOM_JARS_DOWNLOAD}"

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
    curl ${CURL_OPTS} "${url}" -o "$filename" || { echo "Problem with extensions download from ${url}"; continue; }

    jar xf "$filename" || { echo "Problem extracting contents of $filename"; continue; }
    rm "$filename"
  done
fi

cd /opt/connect

exec "$@"









