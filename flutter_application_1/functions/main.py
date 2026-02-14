# functions/main.py
from firebase_functions import https_fn
from firebase_admin import initialize_app
import google.generativeai as genai
import os

# 1. Initialize Firebase
initialize_app()

@https_fn.on_call()
def get_tutor_feedback(req: https_fn.CallableRequest):
    """Takes a score and returns AI-generated encouragement."""
    
    # 2. 从环境变量中安全读取 API Key
    api_key = os.environ.get("GEMINI_API_KEY")
    if not api_key:
        return {"error": "API Key is missing! Check your .env file."}
        
    genai.configure(api_key=api_key)
    model = genai.GenerativeModel('gemini-pro')
    
    # Get the data sent from your Flutter app
    score = req.data.get("score", 0)
    student_name = req.data.get("name", "Student")

    # 3. Create a prompt for the AI
    prompt = f"The student {student_name} got a score of {score}/100. " \
             f"Provide a short, 2-sentence encouraging feedback comment as a friendly tutor."

    try:
        # 4. Ask Gemini for the response
        response = model.generate_content(prompt)
        return {"feedback": response.text}
    except Exception as e:
        return {"error": str(e)}