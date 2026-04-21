"""
App1 — Products Microservice
Runs on port 5001
"""

import os
import json
from flask import Flask, jsonify

app = Flask(__name__)

APP_VERSION = os.getenv("APP_VERSION", "unknown")
ENVIRONMENT = os.getenv("ENVIRONMENT", "development")
PORT = int(os.getenv("PORT", 5001))

PRODUCTS = [
    {"id": 1, "name": "Laptop", "price": 999},
    {"id": 2, "name": "Phone", "price": 699},
    {"id": 3, "name": "Tablet", "price": 499},
]


@app.route("/health")
def health():
    return jsonify({"status": "healthy", "service": "app1-products", "version": APP_VERSION})


@app.route("/")
def index():
    return jsonify({"service": "app1-products", "version": APP_VERSION, "environment": ENVIRONMENT})


@app.route("/products")
def get_products():
    return jsonify({"products": PRODUCTS, "version": APP_VERSION})


@app.route("/products/<int:product_id>")
def get_product(product_id):
    product = next((p for p in PRODUCTS if p["id"] == product_id), None)
    if product:
        return jsonify(product)
    return jsonify({"error": "Product not found"}), 404


if __name__ == "__main__":
    print(f"Starting App1 Products Service v{APP_VERSION} on port {PORT}")
    app.run(host="0.0.0.0", port=PORT)
