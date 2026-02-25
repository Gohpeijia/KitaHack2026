import os
import datetime
import firebase_admin
from firebase_admin import credentials, firestore, messaging
from dotenv import load_dotenv

# 1. Load the .env file
load_dotenv()

# 2. Initialization Logic
def initialize_db():
    if not firebase_admin._apps:
        # Pulls the path to your service_account.json from .env
        key_path = os.getenv("FIREBASE_KEY_PATH")
        cred = credentials.Certificate(key_path)
        firebase_admin.initialize_app(cred)
    return firestore.client()

# --- FIX: CALL THE FUNCTION ---
db = initialize_db()
print("Nudge Engine: Connected and ready!")

def check_and_nudge():
    # Use timezone-aware UTC now to match Firestore timestamps
    now = datetime.datetime.now(datetime.timezone.utc)
    tomorrow = now + datetime.timedelta(hours=24)

    users_ref = db.collection('users')
    
    for user_doc in users_ref.stream():
        user_id = user_doc.id
        user_data = user_doc.to_dict()
        fcm_token = user_data.get('fcm_token')
        
        if not fcm_token:
            continue

        inventory_ref = users_ref.document(user_id).collection('inventory')
        
        # 1. ORIGINAL LOGIC: Expiring tomorrow
        expiring_items = inventory_ref.where('estimated_expiry', '<=', tomorrow).stream()

        for item in expiring_items:
            data = item.to_dict()
            food_name = data.get('name')
            
            # 2. USP LOGIC: Community Bridge (SDG 2)
            if data.get('sharing_eligible') == True:
                title = "🌟 Community Surplus Bridge"
                body = f"You likely won't finish the {food_name}. Tap to share it with your community!"
            else:
                title = "🚨 Waste Alert!"
                body = f"Your {food_name} expires tomorrow. Cook it tonight!"

            # --- ADDED: SAFE SENDING ---
            try:
                message = messaging.Message(
                    notification=messaging.Notification(title=title, body=body),
                    token=fcm_token,
                )
                messaging.send(message)
                print(f"Nudge sent to {user_id} for {food_name}")
            except Exception as send_error:
                print(f"Could not send to {user_id}: {send_error}")

if __name__ == "__main__":
    check_and_nudge()