import firebase_admin
from firebase_admin import credentials, firestore, messaging
import datetime
import os
import json

# 1. initialize Firebase Admin SDK using credentials from environment variable
firebase_creds_json = os.environ.get('FIREBASE_CREDENTIALS')
cred = credentials.Certificate(json.loads(firebase_creds_json))
firebase_admin.initialize_app(cred)

db = firestore.client()

def check_and_nudge():
    # get the current time and the time 24 hours from now
    now = datetime.datetime.now(datetime.timezone.utc)
    tomorrow = now + datetime.timedelta(hours=24)

    # 2. read all users and their inventory from Firestore
    users_ref = db.collection('users')
    for user_doc in users_ref.stream():
        user_id = user_doc.id
        # get the user's FCM token for push notifications
        fcm_token = user_doc.to_dict().get('fcm_token')
        if not fcm_token:
            continue

        # check if any food items are expiring within the next 24 hours
        inventory_ref = users_ref.document(user_id).collection('inventory')
        expiring_items = inventory_ref.where('estimated_expiry', '<=', tomorrow).where('estimated_expiry', '>', now).stream()

        for item in expiring_items:
            item_data = item.to_dict()
            food_name = item_data.get('name', 'ingredient')
            
            # 3. send a push notification to the user about the expiring food
            message = messaging.Message(
                notification=messaging.Notification(
                    title='🚨 Alert！',
                    body=f'Your {food_name} is expiring tomorrow. Use it tonight!'
                ),
                token=fcm_token,
            )
            try:
                response = messaging.send(message)
                print(f"Sending {user_id} about {food_name}: {response} successfully!")
            except Exception as e:
                print(f"Failed to send notification to {user_id}: {e}")

if __name__ == "__main__":
    check_and_nudge()