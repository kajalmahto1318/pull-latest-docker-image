import pytest
from app import app


@pytest.fixture
def client():
    app.config["TESTING"] = True
    with app.test_client() as c:
        yield c


def test_health(client):
    r = client.get("/health")
    assert r.status_code == 200
    data = r.get_json()
    assert data["status"] == "healthy"
    assert data["service"] == "app2-orders"


def test_index(client):
    r = client.get("/")
    assert r.status_code == 200
    assert "app2-orders" in r.get_json()["service"]


def test_orders_list(client):
    r = client.get("/orders")
    assert r.status_code == 200
    assert len(r.get_json()["orders"]) >= 2


def test_create_order(client):
    r = client.post("/orders", json={"product": "Keyboard", "quantity": 3})
    assert r.status_code == 201
    data = r.get_json()
    assert data["product"] == "Keyboard"
    assert data["status"] == "created"
