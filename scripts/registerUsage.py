import boto3
import os
import logging

logging.basicConfig(level=logging.INFO)
client = boto3.client('meteringmarketplace', region_name='us-east-1')

try:
    response = client.register_usage(
        ProductCode="6grgvk2l0exkxkh4gvbzydtz2",
        PublicKeyVersion=1
    )
    print('Response from RegisterUsage API call '+str(response))
    # logging.info('Response from RegisterUsage API call '+str(response))
    # return True
except Exception as e:
    print("Error could not call registerusage api **" + str(e))
    # logging.error("Error could not call registerusage api **" + str(e))
    # return False

# def registerUsage():
#     try:
#         response = client.register_usage(
#             ProductCode=os.environ["PROD_CODE"],
#             PublicKeyVersion=1
#         )
#         print('Response from RegisterUsage API call '+str(response))
#         # logging.info('Response from RegisterUsage API call '+str(response))
#         return True
#     except Exception as e:
#         print("Error could not call registerusage api **" + str(e))
#         # logging.error("Error could not call registerusage api **" + str(e))
#         return False