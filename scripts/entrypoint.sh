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

PGPASSWORD=$MASTER_DATABASE_PASSWORD psql -h $DATABASE_URL -p 5432 -U $MASTER_DATABASE_USERNAME -d postgres -c "DO \$\$ BEGIN IF EXISTS (SELECT FROM pg_catalog.pg_roles WHERE  rolname = '$MP_DATABASE_USERNAME') THEN RAISE NOTICE 'Role $MP_DATABASE_USERNAME already exists. Skipping.'; ELSE CREATE ROLE $MP_DATABASE_USERNAME LOGIN PASSWORD '$MP_DATABASE_PASSWORD'; END IF; END \$\$;"
if PGPASSWORD=$MASTER_DATABASE_PASSWORD psql -h $DATABASE_URL -p 5432 -U $MASTER_DATABASE_USERNAME -d postgres -lqt | cut -d \| -f 1 | grep -qw "$MP_DATABASE_DBNAME"; then     echo "Database $MP_DATABASE_DBNAME already exists. Skipping creation."; else    PGPASSWORD=$MASTER_DATABASE_PASSWORD createdb -h $DATABASE_URL -U $MASTER_DATABASE_USERNAME '$MP_DATABASE_DBNAME';     echo "Database $MP_DATABASE_DBNAME has been created."; fi
PGPASSWORD=$MASTER_DATABASE_PASSWORD psql -h $DATABASE_URL -p 5432 -U $MASTER_DATABASE_USERNAME -d $MP_DATABASE_DBNAME -c "GRANT ALL PRIVILEGES ON DATABASE $MP_DATABASE_DBNAME TO $MP_DATABASE_USERNAME;"

PGPASSWORD=$MP_DATABASE_PASSWORD psql -h $DATABASE_URL -p 5432 -U $MP_DATABASE_USERNAME -d $MP_DATABASE_DBNAME -c "DO \$\$ BEGIN IF NOT EXISTS ( SELECT 1 FROM information_schema.schemata WHERE schema_name = '$MP_DB_SCHEMA') THEN EXECUTE 'CREATE SCHEMA $MP_DB_SCHEMA'; RAISE NOTICE 'Schema "$MP_DB_SCHEMA" has been created.'; ELSE RAISE NOTICE 'Schema "$MP_DB_SCHEMA" already exists.'; END IF; END \$\$;"


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

cd /opt/connect

exec "$@"









