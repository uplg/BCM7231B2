use std::{env, sync::Arc};

use axum::{
    body::{to_bytes, Body},
    http::{Method, Request, StatusCode},
};
use cat_monitor_rust_backend::{auth::Claims, build_app_from_config, config::Config};
use jsonwebtoken::{encode, EncodingKey, Header};
use serde_json::{json, Value};
use tower::ServiceExt;

const LEGACY_BASE_URL: &str = "http://localhost:3033";
const LEGACY_TOKEN: &str = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJ1c2VySWQiOiIxIiwidXNlcm5hbWUiOiJsZW9uYXJkIiwicm9sZSI6ImFkbWluIiwiZXhwIjoxNzczODc0NTE1LCJpYXQiOjE3NzMyNjk3MTV9.iA2VDfv_KLmADqGHI-yXa2fPRom5LqfyKIT2mP3dh6g";

#[tokio::test]
async fn auth_verify_matches_legacy_contract() {
    let rust = request_rust(Method::POST, "/api/auth/verify", None, Some(rust_test_token())).await;
    let legacy = request_legacy(Method::POST, "/auth/verify", None, Some(LEGACY_TOKEN.to_string())).await;

    assert_eq!(rust.0, StatusCode::OK);
    assert_eq!(rust.0, legacy.0);
    assert_json_eq(&normalize_verify_response(rust.1), &normalize_verify_response(legacy.1));
}

#[tokio::test]
async fn auth_logout_matches_legacy_contract() {
    let rust = request_rust(Method::POST, "/api/auth/logout", None, None).await;
    let legacy = request_legacy(Method::POST, "/auth/logout", None, None).await;

    assert_eq!(rust.0, StatusCode::OK);
    assert_eq!(rust.0, legacy.0);
    assert_json_eq(&rust.1, &legacy.1);
}

#[tokio::test]
async fn auth_invalid_login_matches_legacy_contract() {
    let body = json!({ "username": "nope", "password": "nope" });
    let rust = request_rust(Method::POST, "/api/auth/login", Some(body.clone()), None).await;
    let legacy = request_legacy(Method::POST, "/auth/login", Some(body), None).await;

    assert_eq!(rust.0, StatusCode::UNAUTHORIZED);
    assert_eq!(rust.0, legacy.0);
    assert_json_eq(&rust.1, &legacy.1);
}

async fn request_rust(
    method: Method,
    path: &str,
    body: Option<Value>,
    token: Option<String>,
) -> (StatusCode, Value) {
    let config = test_config();
    let app = build_app_from_config(Arc::new(config)).expect("failed to build test app");

    let mut builder = Request::builder().method(method).uri(path);
    if let Some(token) = token {
        builder = builder.header("Authorization", format!("Bearer {token}"));
    }
    if body.is_some() {
        builder = builder.header("Content-Type", "application/json");
    }

    let request_body = body
        .map(|value| Body::from(serde_json::to_vec(&value).expect("body json should encode")))
        .unwrap_or_else(Body::empty);
    let request = builder.body(request_body).expect("request should build");

    let response = app.oneshot(request).await.expect("request should succeed");
    let status = response.status();
    let body = to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("body should be readable");
    let json = serde_json::from_slice::<Value>(&body).expect("response should be valid json");
    (status, json)
}

async fn request_legacy(
    method: Method,
    path: &str,
    body: Option<Value>,
    token: Option<String>,
) -> (StatusCode, Value) {
    let client = reqwest::Client::new();
    let mut request = client.request(method, format!("{LEGACY_BASE_URL}{path}"));
    if let Some(token) = token {
        request = request.bearer_auth(token);
    }
    if let Some(body) = body {
        request = request.json(&body);
    }

    let response = request.send().await.expect("legacy request should succeed");
    let status = response.status();
    let json = response
        .json::<Value>()
        .await
        .expect("legacy response should be valid json");
    (status, json)
}

fn test_config() -> Config {
    let root = workspace_root();
    let source_root = root.join("web-project").join("cat-monitor");
    Config {
        host: "127.0.0.1".to_string(),
        port: 0,
        jwt_secret: env::var("JWT_SECRET").unwrap_or_else(|_| "super-secret-cat-key-change-me".to_string()),
        users_path: source_root.join("users.json"),
        meross_devices_path: source_root.join("meross-devices.json"),
        source_root,
    }
}

fn workspace_root() -> std::path::PathBuf {
    std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("backend has parent")
        .parent()
        .expect("rust-rewrite has parent")
        .parent()
        .expect("web-project has parent")
        .to_path_buf()
}

fn rust_test_token() -> String {
    let claims = Claims {
        user_id: "1".to_string(),
        username: "leonard".to_string(),
        role: "admin".to_string(),
        exp: 4_102_444_800,
    };

    encode(
        &Header::default(),
        &claims,
        &EncodingKey::from_secret(
            env::var("JWT_SECRET")
                .unwrap_or_else(|_| "super-secret-cat-key-change-me".to_string())
                .as_bytes(),
        ),
    )
    .expect("test token should encode")
}

fn normalize_verify_response(value: Value) -> Value {
    json!({
        "success": value.get("success").cloned().unwrap_or(Value::Null),
        "user": value.get("user").cloned().unwrap_or(Value::Null),
    })
}

fn assert_json_eq(left: &Value, right: &Value) {
    assert_eq!(left, right, "left:\n{}\n\nright:\n{}", pretty(left), pretty(right));
}

fn pretty(value: &Value) -> String {
    serde_json::to_string_pretty(value).expect("json should pretty print")
}
