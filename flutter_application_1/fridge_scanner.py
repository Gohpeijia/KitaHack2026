import os
import json
import datetime
import google.generativeai as genai
import firebase_admin
from firebase_admin import credentials, firestore
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

def save_to_firebase(ai_results, user_id):
    # Fixed: Use the 'db' initialized at the top
    user_ref = db.collection('users').document(user_id)
    
    # Fixed: Key name changed to 'behavioral_insight' to match AI output
    user_ref.update({"latest_insight": ai_results['behavioral_insight']})
    
    for item in ai_results['inventory']:
        user_ref.collection('inventory').add({
            "name": item['name'],
            "sharing_eligible": item['sharing_eligible'],
            # Fixed: Key name changed to 'expiry_days' to match AI output
            "estimated_expiry": datetime.datetime.now() + datetime.timedelta(days=item['expiry_days'])
        })

if __name__ == "__main__":
    try:
        # Use a real fridge image path here
        results = analyze_fridge_with_usp("fridge.jpg")
        
        # Fixed: Using the specific UID for your teammate's account
        save_to_firebase(results, user_id="8AhvDGBQ0zbxm1CrBkJqBO8nCzp1")
        
        print(json.dumps(results, indent=2))
        print("\n✅ AI Analysis successfully saved to Firebase!")
    except Exception as e:
        print(f"Error: {e}")