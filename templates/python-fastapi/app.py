from fastapi import FastAPI
from pydantic import BaseModel

app = FastAPI(title="myapi", version="0.1.0")


class EchoIn(BaseModel):
    message: str


@app.get("/healthz")
def healthz() -> dict:
    return {"status": "ok"}


@app.get("/")
def index() -> dict:
    return {"message": "hello from fastapi"}


@app.post("/echo")
def echo(body: EchoIn) -> dict:
    return {"echo": body.message}
