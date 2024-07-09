#!/bin/bash

# Define the arguments
DATABASE=${DATABASE:-postgres}
DATABASE_URL=${DATABASE_URL:-jdbc:postgresql://db:5432/mirthdb}
DATABASE_MAX_CONNECTIONS=${DATABASE_MAX_CONNECTIONS:-20}
DATABASE_USERNAME=${DATABASE_USERNAME:-mirthdb}
DATABASE_PASSWORD=${DATABASE_PASSWORD:-mirthdb}
DATABASE_MAX_RETRY=${DATABASE_MAX_RETRY:-2}
DATABASE_RETRY_WAIT=${DATABASE_RETRY_WAIT:-10000}
KEYSTORE_STOREPASS=${KEYSTORE_STOREPASS:-docker_storepass}
KEYSTORE_KEYPASS=${KEYSTORE_KEYPASS:-docker_keypass}
VMOPTIONS=${VMOPTIONS:-"-Xmx512m"}

# File to be modified
FILE="mirth.properties"

# Function to update a property in the file
update_property() {
  local property=$1
  local value=$2
  if grep -q "^${property}=" "$FILE"; then
    sed -i "s|^${property}=.*|${property}=${value}|" "$FILE"
  else
    echo "${property}=${value}" >> "$FILE"
  fi
}

# Update the properties in the file
update_property "database" "$DATABASE"
update_property "database.url" "$DATABASE_URL"
update_property "database.max_connections" "$DATABASE_MAX_CONNECTIONS"
update_property "database.username" "$DATABASE_USERNAME"
update_property "database.password" "$DATABASE_PASSWORD"
update_property "database.max_retry" "$DATABASE_MAX_RETRY"
update_property "database.retry_wait" "$DATABASE_RETRY_WAIT"
update_property "keystore.storepass" "$KEYSTORE_STOREPASS"
update_property "keystore.keypass" "$KEYSTORE_KEYPASS"
update_property "vmoptions" "$VMOPTIONS"

echo "Configuration updated in $FILE"
