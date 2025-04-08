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


if ! [ -z "${KEYSTORE_TYPE+x}" ]; then
	sed -i "s/^keystore\.type\s*=\s*.*\$/keystore.type = ${KEYSTORE_TYPE//\//\\/}/" /opt/bridgelink/conf/mirth.properties
fi


# database max connections
if ! [ -z "${DATABASE_MAX_CONNECTIONS+x}" ]; then
	sed -i "s/^database\.max-connections\s*=\s*.*\$/database.max-connections = ${DATABASE_MAX_CONNECTIONS//\//\\/}/" /opt/bridgelink/conf/mirth.properties
fi

# database max retries
if ! [ -z "${DATABASE_MAX_RETRY+x}" ]; then
	sed -i "s/^database\.connection\.maxretry\s*=\s*.*\$/database.connection.maxretry = ${DATABASE_MAX_RETRY//\//\\/}/" /opt/bridgelink/conf/mirth.properties
fi

# database retry wait time
if ! [ -z "${DATABASE_RETRY_WAIT+x}" ]; then
	sed -i "s/^database\.connection\.retrywaitinmilliseconds\s*=\s*.*\$/database.connection.retrywaitinmilliseconds = ${DATABASE_RETRY_WAIT//\//\\/}/" /opt/bridgelink/conf/mirth.properties
fi

# merge extra environment variables starting with _MP_ into mirth.properties
while read -r keyvalue; do
	KEY="${keyvalue%%=*}"
	VALUE="${keyvalue#*=}"
	VALUE=$(tr -dc '\40-\176' <<< "$VALUE")

	if ! [ -z "${KEY}" ] && ! [ -z "${VALUE}" ] && ! [[ ${VALUE} =~ ^\ +$ ]]; then

		# filter for variables starting with "_MP_"
		if [[ ${KEY} == _MP_* ]]; then

			# echo "found mirth property ${KEY}=${VALUE}"

			# example: _MP_DATABASE_MAX__CONNECTIONS -> database.max-connections

			# remove _MP_
			# example:  DATABASE_MAX__CONNECTIONS
			ACTUAL_KEY=${KEY:4}

			# switch '__' to '-'
			# example:  DATABASE_MAX-CONNECTIONS
			ACTUAL_KEY="${ACTUAL_KEY//__/-}"

			# switch '_' to '.'
			# example:  DATABASE.MAX-CONNECTIONS
			ACTUAL_KEY="${ACTUAL_KEY//_/.}"

			# lower case
			# example:  database.max-connections
			ACTUAL_KEY="${ACTUAL_KEY,,}"

			# if key does not exist in mirth.properties append it at bottom
			LINE_COUNT=`grep "^${ACTUAL_KEY}" $PROPERTIES_FILE | wc -l`
			if [ $LINE_COUNT -lt 1 ]; then
				# echo "key ${ACTUAL_KEY} not found in mirth.properties, appending. Value = ${VALUE}"
				echo -e "\n${ACTUAL_KEY} = ${VALUE//\//\\/}" >> $PROPERTIES_FILE
			else # otherwise key exists, overwrite it
				# echo "key ${ACTUAL_KEY} exists, overwriting. Value = ${VALUE}"
				ESCAPED_KEY="${ACTUAL_KEY//./\\.}"
				sed -i "s/^${ESCAPED_KEY}\s*=\s*.*\$/${ACTUAL_KEY} = ${VALUE//\//\\/}/" $PROPERTIES_FILE
			fi
		fi
	fi
done <<< "`printenv`"


cd /opt/bridgelink

exec "$@"









