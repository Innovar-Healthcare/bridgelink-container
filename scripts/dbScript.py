import boto3
import json
import psycopg2
import os
from psycopg2 import sql

# Function to fetch credentials from AWS Secrets Manager
def get_secret(secret_name, region_name):
    try:
        # Create a Secrets Manager client
        session = boto3.session.Session()
        client = session.client(service_name="secretsmanager", region_name=region_name)
        
        # Fetch the secret
        get_secret_value_response = client.get_secret_value(SecretId=secret_name)
        secret = get_secret_value_response['SecretString']
        
        return json.loads(secret)  # Convert secret JSON string to dictionary
    
    except Exception as e:
        print(f"Error retrieving secret: {e}")
        return None



# Function to connect to the database
def connect_db(dbname):
    return psycopg2.connect(
        dbname=dbname,
        user=MASTER_DATABASE_USERNAME,
        password=MASTER_DATABASE_PASSWORD,
        host=DATABASE_URL,
        port=5432
    )

# Function to create role if not exists
def create_role_if_not_exists(conn):
    with conn.cursor() as cur:
        sql_command = """
        DO $$
        DECLARE
            role_name text := %s;
            role_password text := %s;
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name) THEN
                EXECUTE 'CREATE ROLE ' || quote_ident(role_name) || ' LOGIN PASSWORD ' || quote_literal(role_password);
                RAISE NOTICE 'Role has been created.';
            ELSE
                RAISE NOTICE 'Role already exists. Skipping.';
            END IF;
        END $$;
        """
        cur.execute(sql_command, (MP_DATABASE_USERNAME, MP_DATABASE_PASSWORD))
    conn.commit()

# Function to check if database exists
def database_exists(conn, dbname):
    with conn.cursor() as cur:
        cur.execute("SELECT 1 FROM pg_database WHERE datname = %s", (dbname,))
        return cur.fetchone() is not None

# Function to create database if not exists
def create_database_if_not_exists(conn, database_name):
    conn.autocommit = True
    with conn.cursor() as cur:
        try:
            cur.execute("SELECT 1 FROM pg_database WHERE datname = %s", (database_name,))
            if cur.fetchone():
                print(f"Database '{database_name}' already exists. Skipping creation.")
            else:
                cur.execute(sql.SQL("CREATE DATABASE {}").format(sql.Identifier(database_name)))
                print(f"Database '{database_name}' has been created.")
        except psycopg2.Error as e:
            print(f"Error while creating database: {e}")
        finally:
            conn.autocommit = False

# Function to grant privileges on the database
def grant_privileges(conn):
    with conn.cursor() as cur:
        cur.execute(sql.SQL("GRANT ALL PRIVILEGES ON DATABASE {} TO {}").format(
            sql.Identifier(MP_DATABASE_DBNAME),
            sql.Identifier(MP_DATABASE_USERNAME)
        ))
    conn.commit()

# Function to create schema if not exists
def create_schema_if_not_exists():
    conn = psycopg2.connect(
        dbname=MP_DATABASE_DBNAME,
        user=MP_DATABASE_USERNAME,
        password=MP_DATABASE_PASSWORD,
        host=DATABASE_URL,
        port=5432
    )
    with conn.cursor() as cur:
        sql_command = """
            DO $$
            DECLARE
                mc_schema_name text := %s;
            BEGIN
                IF NOT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = mc_schema_name) THEN
                    EXECUTE 'CREATE SCHEMA ' || quote_ident(mc_schema_name);
                    RAISE NOTICE 'Schema has been created.';
                ELSE
                    RAISE NOTICE 'Schema already exists.';
                END IF;
            END $$;
        """
        cur.execute(sql_command, (MP_DB_SCHEMA,))
    conn.commit()
    conn.close()

# Main script execution
if __name__ == "__main__":
    # Create a session object
    session = boto3.Session()

    # Get the current region
    region_name = session.region_name
    secret_name = os.getenv("AWS_SECRETS_MANAGER_NAME")

    # Retrieve database credentials from AWS Secrets Manager
    secrets = get_secret(secret_name, region_name)

    if not secrets:
        raise ValueError("Failed to retrieve database secrets.")

    # Extract credentials from secrets
    MASTER_DATABASE_USERNAME = secrets.get("master_username")
    MASTER_DATABASE_PASSWORD = secrets.get("master_password")
    DATABASE_URL = secrets.get("host")
    MP_DATABASE_USERNAME = secrets.get("mp_username")
    MP_DATABASE_PASSWORD = secrets.get("mp_password")
    MP_DATABASE_DBNAME = secrets.get("mp_dbname")
    MP_DB_SCHEMA = secrets.get("mp_schema")

    conn = connect_db('postgres')
    create_role_if_not_exists(conn)
    create_database_if_not_exists(conn, MP_DATABASE_DBNAME)
    
    conn = connect_db(MP_DATABASE_DBNAME)
    grant_privileges(conn)
    create_schema_if_not_exists()
    
    conn.close()
