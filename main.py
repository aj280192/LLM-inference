"""Minimal chat app skeleton — replace with your real application."""
from fastapi import FastAPI
from pydantic import BaseModel

app = FastAPI()


class ChatRequest(BaseModel):
    message: str


@app.get("/health")
def health():
    # TODO: deepen this — verify LLM provider + vector DB reachability
    return {"status": "ok"}


@app.post("/chat")
def chat(req: ChatRequest):
    from app_logic.chat import get_response  # your real logic
    return {"reply": get_response(req.message)}
