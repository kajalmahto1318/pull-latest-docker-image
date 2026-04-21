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
    assert data["service"] == "app1-products"


def test_index(client):
    r = client.get("/")
    assert r.status_code == 200
    assert "app1-products" in r.get_json()["service"]


def test_products_list(client):
    r = client.get("/products")
    assert r.status_code == 200
    assert len(r.get_json()["products"]) == 3


def test_product_by_id(client):
    r = client.get("/products/1")
    assert r.status_code == 200
    assert r.get_json()["name"] == "Laptop"


def test_product_not_found(client):
    r = client.get("/products/999")
    assert r.status_code == 404
