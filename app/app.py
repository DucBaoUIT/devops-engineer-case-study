from flask import Flask, jsonify
import os, time
app=Flask(__name__)
@app.get("/")
def home(): return jsonify(service="demo-web", message=os.getenv("APP_MESSAGE","Hello from DevOps case study - 17-10-2026"), version=os.getenv("APP_VERSION","local"))
@app.get("/health")
def health(): return jsonify(status="ok"), 200
@app.get("/slow")
def slow():
    time.sleep(float(os.getenv("SLOW_ENDPOINT_SECONDS","0")))
    return jsonify(status="completed"), 200
if __name__=="__main__": app.run(host="0.0.0.0",port=int(os.getenv("PORT","8080")))
