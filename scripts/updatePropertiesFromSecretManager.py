import boto3
import json
import os

def get_secret(secret_name, region_name):
    # Create a Secrets Manager client
    session = boto3.session.Session()
    client = session.client(service_name="secretsmanager", region_name=region_name)
    
    try:
        get_secret_value_response = client.get_secret_value(SecretId=secret_name)
        secret = get_secret_value_response['SecretString']
        return json.loads(secret)
    except Exception as e:
        print(f"Error retrieving secret: {e}")
        return None

def update_mirth_properties(db_url, db_user, db_password):
    # mirth_properties_path = os.environ.get('MIRTH_PROPERTIES_PATH', '/opt/mirth-connect/appdata/mirth.properties')
    mirth_properties_path = '/opt/connect/conf/mirth.properties'
    try:
        with open(mirth_properties_path, 'r') as file:
            lines = file.readlines()

        with open(mirth_properties_path, 'w') as file:
            for line in lines:
                if 'database.url =' in line:
                    file.write(f'database.url =jdbc:postgresql://{db_url}:5432/{db_database}?currentSchema={db_schema}\n')
                elif 'database.username =' in line:
                    file.write(f'database.username ={db_user}\n')
                elif 'database.password =' in line:
                    file.write(f'database.password ={db_password}\n')
                elif 'database =' in line:
                    file.write(f'database =postgres\n')
                else:
                    file.write(line)
    except Exception as e:
        print(f"Error updating mirth.properties: {e}")

if __name__ == '__main__':
    # Create a session object
    session = boto3.Session()

    # Get the current region
    region_name = session.region_name
    secret_name = os.getenv("AWS_SECRETS_MANAGER_NAME")

    
    secret = get_secret(secret_name, region_name)
    if secret:
        db_url = secret.get('host')
        db_schema = secret.get('mp_schema')
        db_database = secret.get('mp_dbname')
        db_user = secret.get('mp_username')
        db_password = secret.get('mp_password')

        if db_url and db_user and db_password:
            update_mirth_properties(db_url, db_user, db_password)
        else:
            print("Error: Missing required database fields in secret")
    else:
        print("Error: Failed to retrieve secret")
