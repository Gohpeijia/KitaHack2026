import os
import json
import datetime
import google.generativeai as genai
import firebase_admin
from firebase_admin import credentials, firestore, storage
from dotenv import load_dotenv
from PIL import Image

# 1. Setup environment and database
load_dotenv()

def initialize_db():
    if not firebase_admin._apps:
        key_path = os.getenv("FIREBASE_KEY_PATH")
        cred = credentials.Certificate(key_path)
        firebase_admin.initialize_app(cred)
    return firestore.client()

db = initialize_db()
print("Connected to Kitahack2026 Firebase!")

# 2. Configure Gemini AI
genai.configure(api_key=os.getenv("GEMINI_API_KEY"))

SYSTEM_RULES = """
You are the FridgeGuardian Waste-Pattern AI. 
Your goal is SDG 12.8: behavior intervention to reduce waste.

When analyzing an image or inventory data, you must provide:
1. INVENTORY: Items, categories, and expiry.
2. BEHAVIORAL NUDGE: Analyze patterns like over-buying large sizes.
3. SURPLUS STRATEGY: Flag items for 'Community Sharing'.

OUTPUT ONLY VALID JSON:
{
  "inventory": [{"name": "Milk", "expiry_days": 2, "sharing_eligible": true}],
  "behavioral_insight": "You often leave 1L milk cartons unfinished. Next time, try buying 500ml.",
  "sdg_impact": "Switching to smaller sizes reduces your dairy waste by 30%."
}
"""

model = genai.GenerativeModel(
    model_name="gemini-2.5-flash", 
    system_instruction=SYSTEM_RULES
)

def analyze_fridge_with_usp(image_path):
    img = Image.open(image_path)
    response = model.generate_content(
        [img, "Analyze my habits and fridge content."],
        generation_config={"response_mime_type": "application/json"}
    )
    return json.loads(response.text)

def download_user_image(user_id):
    """Downloads the image uploaded by the Flutter app from Firebase Storage."""
    # The bucket name is usually your Project ID + '.appspot.com'
    bucket = storage.bucket(name="kitahack2026-c2a42.appspot.com") 
    
    # We assume Daniel's Flutter app saves the image as 'user_id.jpg'
    blob = bucket.blob(f"fridge_images/{user_id}.jpg")
    
    local_filename = f"temp_{user_id}.jpg"
    blob.download_to_filename(local_filename)
    print(f"✅ Downloaded latest image for user: {user_id}")
    return local_filename

def save_to_firebase(ai_results, user_id):
    user_ref = db.collection('users').document(user_id)
    user_ref.update({"latest_insight": ai_results['behavioral_insight']})
    
    for item in ai_results['inventory']:
        user_ref.collection('inventory').add({
            "name": item['name'],
            "status": "active",  # Add this line to avoid the Zombie Bug
            "sharing_eligible": item['sharing_eligible'],
            "estimated_expiry": datetime.datetime.now() + datetime.timedelta(days=item['expiry_days'])
        })

if __name__ == "__main__":
    target_user = "8AhvDGBQ0zbxm1CrBkJqBO8nCzp1" # Daniel's UID
    
    try:
        # STEP 1: Download the actual image uploaded by the user
        current_image_path = download_user_image(target_user)
        
        # STEP 2: Analyze the downloaded image
        results = analyze_fridge_with_usp(current_image_path)
        
        # STEP 3: Save results to the database
        save_to_firebase(results, user_id=target_user)
        
        print(json.dumps(results, indent=2))
        print("\n✅ AI Analysis successfully saved to Firebase!")
        
        # Cleanup: Remove the temporary file after scanning
        if os.path.exists(current_image_path):
            os.remove(current_image_path)
            
    except Exception as e:
        print(f"Error: {e}")