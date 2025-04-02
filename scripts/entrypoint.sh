#!/bin/bash

# Files to be modified
PROPERTIES_FILE="/opt/bridgelink/conf/mirth.properties"
VMOPTIONS_FILE="/opt/bridgelink/blserver.vmoptions"
SERVER_ID_FILE="/opt/bridgelink/appdata/server.id"
EXTENSIONS_DIR="/opt/bridgelink/extensions"
CUSTOM_JARS_DIR="/opt/bridgelink/custom-jars"
S3_CUSTOM_JARS_DIR="/opt/bridgelink/S3_custom-jars"

Function to update a property in the file
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

# Check and write SERVER_ID to the specified file
if [ ! -z "$SERVER_ID" ]; then
  echo -e "server.id = ${SERVER_ID//\//\\/}" > "$SERVER_ID_FILE"
fi

# #Create pg user ,database, schema
# python3 /opt/scripts/dbScript.py

# #AWS Marketplace usage registration
# # python3 /opt/scripts/registerUsage.py registerUsage

# #Get information from secret manager
# python3 /opt/scripts/updatePropertiesFromSecretManager.py




# Calculate 75% of total ECS task def
# xmx_value_mb=$(($TOTAL_MEMORY * 80 / 100))
# rounded_xmx_value_mb=$((xmx_value_mb / 1024 * 1024))
# sed -i "s/-Xmx[0-9]*m/-Xmx${rounded_xmx_value_mb}m/" $VMOPTIONS_FILE


# # Use aws cli command to download custom mcserver.vmoption to container
# if [ -n "${S3_VPMOPTIONS_URL}" ]; then
#   echo "Download vmoptions file from url... ${S3_VPMOPTIONS_URL}"

#   aws s3 cp ${S3_VPMOPTIONS_URL} ${VMOPTIONS_FILE}
# fi

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

# # Download and extract extensions if EXTENSIONS_DOWNLOAD is set
# if [ -n "${EXTENSIONS_DOWNLOAD}" ]; then
#   echo "Downloading extensions from ${EXTENSIONS_DOWNLOAD}"
#   cd ${EXTENSIONS_DIR}

#   CURL_OPTS="-sSLf"
#   [ "${ALLOW_INSECURE}" = "true" ] && CURL_OPTS="-ksSLf"

#   # Split URLs by space and iterate over them
#   IFS=',' read -r -a urls <<< "${EXTENSIONS_DOWNLOAD}"
#   for url in "${urls[@]}"; do
#     echo "Downloading from ${url}"
#     # Extract filename from URL
#     filename=$(basename "$url")
#     curl ${CURL_OPTS} "${url}" -o "$filename" || { echo "Problem with extensions download from ${url}"; continue; }

#     echo "Extracting contents of $filename"

#     jar xf "$filename" || { echo "Problem extracting contents of $filename"; continue; }
#     rm "$filename"
#   done
# fi

# # Download and extract jars if CUSTOM_JARS_DOWNLOAD is set
# if [ -n "${CUSTOM_JARS_DOWNLOAD}" ]; then
#   echo "Downloading jars from ${CUSTOM_JARS_DOWNLOAD}"

#   mkdir ${CUSTOM_JARS_DIR}

#   cd ${CUSTOM_JARS_DIR}

#   CURL_OPTS="-sSLf"
#   [ "${ALLOW_INSECURE}" = "true" ] && CURL_OPTS="-ksSLf"

#   # Split URLs by space and iterate over them
#   IFS=',' read -r -a urls <<< "${CUSTOM_JARS_DOWNLOAD}"
#   for url in "${urls[@]}"; do
#     echo "Downloading from ${url}"
#     # Extract filename from URL
#     filename=$(basename "$url")
#     curl ${CURL_OPTS} "${url}" -o "$filename" || { echo "Problem with jars download from ${url}"; continue; }

#     jar xf "$filename" || { echo "Problem extracting contents of $filename"; continue; }
#     rm "$filename"
#   done
# fi

# # Use aws cli command to sync the S3 folder
# if [ -n "${S3_URL}" ]; then
#   mkdir ${S3_CUSTOM_JARS_DIR}
#   echo "S3 sync from ${S3_URL}"

#   aws s3 sync ${S3_URL} ${S3_CUSTOM_JARS_DIR}
# fi

cd /opt/bridgelink

exec "$@"









