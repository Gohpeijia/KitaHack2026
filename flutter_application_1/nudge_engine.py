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

# ... (Keep your friend's existing Firebase initialization code here)

def check_and_nudge():
    now = datetime.datetime.now(datetime.timezone.utc)
    tomorrow = now + datetime.timedelta(hours=24)

    users_ref = db.collection('users')
    for user_doc in users_ref.stream():
        user_id = user_doc.id
        fcm_token = user_doc.to_dict().get('fcm_token')
        if not fcm_token: continue

        inventory_ref = users_ref.document(user_id).collection('inventory')
        
        # 1. ORIGINAL LOGIC: Expiring tomorrow
        expiring_items = inventory_ref.where('estimated_expiry', '<=', tomorrow).stream()

        for item in expiring_items:
            data = item.to_dict()
            food_name = data.get('name')
            
            # 2. USP LOGIC: Community Bridge (SDG 2)
            # If the AI flagged it for sharing, send a special 'Donate' nudge
            if data.get('sharing_eligible') == True:
                title = "🌟 Community Surplus Bridge"
                body = f"You likely won't finish the {food_name}. Tap to share it with your community!"
            else:
                title = "🚨 Waste Alert!"
                body = f"Your {food_name} expires tomorrow. Cook it tonight!"

            message = messaging.Message(
                notification=messaging.Notification(title=title, body=body),
                token=fcm_token,
            )
            messaging.send(message)

if __name__ == "__main__":
    check_and_nudge()