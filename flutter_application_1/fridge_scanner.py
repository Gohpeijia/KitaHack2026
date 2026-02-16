import os
import json
import datetime
import google.generativeai as genai
from dotenv import load_dotenv
from PIL import Image

from firebase_admin import firestore
load_dotenv()
genai.configure(api_key=os.getenv("GEMINI_API_KEY"))

# THE USP LOGIC: Behavior Intervention & Waste Patterns
SYSTEM_RULES = """
You are the FridgeGuardian Waste-Pattern AI. 
Your goal is SDG 12.8: behavior intervention to reduce waste.

When analyzing an image or inventory data, you must provide:
1. INVENTORY: Items, categories, and expiry.
2. BEHAVIORAL NUDGE: Analyze if the user is over-buying. 
   - Example: If you see multiple time half-used large containers, suggest smaller sizes.
3. SURPLUS STRATEGY: If an item cannot be finished, flag it for 'Community Sharing'.

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
    db = firestore.client()
    # This sends your AI insights into the database your friend is using
    user_ref = db.collection('users').document(user_id)
    
    # Save the pattern insight (USP)
    user_ref.update({"latest_insight": ai_results['pattern_insight']})
    
    # Save each food item
    for item in ai_results['inventory']:
        user_ref.collection('inventory').add({
            "name": item['name'],
            "sharing_eligible": item['sharing_eligible'],
            "estimated_expiry": datetime.datetime.now() + datetime.timedelta(days=item['days_left'])
        })





if __name__ == "__main__":
    # Test your new USP logic
    try:
        results = analyze_fridge_with_usp("fridge.jpg")
        save_to_firebase(results, user_id="test_user_Daniel")
        print(json.dumps(results, indent=2))
    except Exception as e:
        print(f"Error: {e}")