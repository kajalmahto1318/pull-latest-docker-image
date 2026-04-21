"""
App2 — Orders Microservice
Runs on port 5002
"""

import os
import uuid
from datetime import datetime
from flask import Flask, jsonify, request

app = Flask(__name__)

APP_VERSION = os.getenv("APP_VERSION", "unknown")
ENVIRONMENT = os.getenv("ENVIRONMENT", "development")
PORT = int(os.getenv("PORT", 5002))

ORDERS = [
    {"id": "ord-001", "product": "Laptop", "quantity": 1, "status": "shipped"},
    {"id": "ord-002", "product": "Phone", "quantity": 2, "status": "processing"},
]


@app.route("/health")
def health():
    return jsonify({"status": "healthy", "service": "app2-orders", "version": APP_VERSION})


@app.route("/")
def index():
    return jsonify({"service": "app2-orders", "version": APP_VERSION, "environment": ENVIRONMENT})


@app.route("/orders")
def get_orders():
    return jsonify({"orders": ORDERS, "version": APP_VERSION})


@app.route("/orders", methods=["POST"])
def create_order():
    data = request.get_json(silent=True) or {}
    order = {
        "id": f"ord-{uuid.uuid4().hex[:6]}",
        "product": data.get("product", "Unknown"),
        "quantity": data.get("quantity", 1),
        "status": "created",
        "created_at": datetime.utcnow().isoformat(),
    }
    ORDERS.append(order)
    return jsonify(order), 201


if __name__ == "__main__":
    print(f"Starting App2 Orders Service v{APP_VERSION} on port {PORT}")
    app.run(host="0.0.0.0", port=PORT)
