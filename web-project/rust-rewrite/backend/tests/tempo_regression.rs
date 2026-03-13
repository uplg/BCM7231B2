use std::{env, sync::Arc};

use axum::{
    body::{to_bytes, Body},
    http::{Request, StatusCode},
};
use cat_monitor_rust_backend::{auth::Claims, build_app_from_config, config::Config};
use jsonwebtoken::{encode, EncodingKey, Header};
use serde_json::{json, Value};
use tower::ServiceExt;

const LEGACY_BASE_URL: &str = "http://localhost:3033";
const LEGACY_TOKEN: &str = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJ1c2VySWQiOiIxIiwidXNlcm5hbWUiOiJsZW9uYXJkIiwicm9sZSI6ImFkbWluIiwiZXhwIjoxNzczODc0NTE1LCJpYXQiOjE3NzMyNjk3MTV9.iA2VDfv_KLmADqGHI-yXa2fPRom5LqfyKIT2mP3dh6g";

#[tokio::test]
async fn tempo_state_matches_legacy_contract() {
    let rust = request_rust("/api/tempo/state").await;
    let legacy = request_legacy("/tempo/state").await;

    assert_eq!(rust.0, StatusCode::OK);
    assert_eq!(rust.0, legacy.0);
    assert_json_eq(&normalize_state_response(rust.1), &normalize_state_response(legacy.1));
}

#[tokio::test]
async fn tempo_predictions_match_legacy_contract() {
    let rust = request_rust("/api/tempo/predictions").await;
    let legacy = request_legacy("/tempo/predictions").await;

    assert_eq!(rust.0, StatusCode::OK);
    assert_eq!(rust.0, legacy.0);
    assert_json_eq(
        &normalize_predictions_response(rust.1),
        &normalize_predictions_response(legacy.1),
    );
}

#[tokio::test]
async fn tempo_calendar_matches_legacy_contract() {
    let rust = request_rust("/api/tempo/calendar").await;
    let legacy = request_legacy("/tempo/calendar").await;

    assert_eq!(rust.0, StatusCode::OK);
    assert_eq!(rust.0, legacy.0);
    assert_json_eq(
        &normalize_calendar_response(rust.1),
        &normalize_calendar_response(legacy.1),
    );
}

#[tokio::test]
async fn tempo_history_matches_legacy_contract() {
    let rust = request_rust("/api/tempo/history").await;
    let legacy = request_legacy("/tempo/history").await;

    assert_eq!(rust.0, StatusCode::OK);
    assert_eq!(rust.0, legacy.0);
    assert_json_eq(&normalize_history_response(rust.1), &normalize_history_response(legacy.1));
}

#[tokio::test]
async fn tempo_calibration_matches_legacy_contract() {
    let rust = request_rust("/api/tempo/calibration").await;
    let legacy = request_legacy("/tempo/calibration").await;

    assert_eq!(rust.0, StatusCode::OK);
    assert_eq!(rust.0, legacy.0);
    assert_json_eq(
        &normalize_calibration_response(rust.1),
        &normalize_calibration_response(legacy.1),
    );
}

async fn request_rust(path: &str) -> (StatusCode, Value) {
    let config = test_config();
    let token = rust_test_token(&config.jwt_secret);
    let app = build_app_from_config(Arc::new(config)).expect("failed to build test app");

    let request = Request::builder()
        .method("GET")
        .uri(path)
        .header("Authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .expect("request should build");

    let response = app.oneshot(request).await.expect("request should succeed");
    let status = response.status();
    let body = to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("body should be readable");
    let json = serde_json::from_slice::<Value>(&body).expect("response should be valid json");
    (status, json)
}

async fn request_legacy(path: &str) -> (StatusCode, Value) {
    let client = reqwest::Client::new();
    let response = client
        .get(format!("{LEGACY_BASE_URL}{path}"))
        .bearer_auth(LEGACY_TOKEN)
        .send()
        .await
        .expect("legacy request should succeed");
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
        disable_bluetooth: true,
        users_path: source_root.join("users.json"),
        meross_devices_path: source_root.join("meross-devices.json"),
        devices_path: source_root.join("devices.json"),
        device_cache_path: source_root.join("device-cache.json"),
        broadlink_codes_path: source_root.join("broadlink-codes.json"),
        hue_lamps_path: source_root.join("hue-lamps.json"),
        hue_blacklist_path: source_root.join("hue-lamps-blacklist.json"),
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

fn rust_test_token(secret: &str) -> String {
    let claims = Claims {
        user_id: "1".to_string(),
        username: "tempo-regression".to_string(),
        role: "admin".to_string(),
        exp: 4_102_444_800,
    };

    encode(
        &Header::default(),
        &claims,
        &EncodingKey::from_secret(secret.as_bytes()),
    )
    .expect("test token should encode")
}

fn normalize_state_response(value: Value) -> Value {
    normalize_json_numbers(json!({
        "success": value.get("success").cloned().unwrap_or(Value::Null),
        "season": value.get("season").cloned().unwrap_or(Value::Null),
        "stock_red_remaining": value.get("stock_red_remaining").cloned().unwrap_or(Value::Null),
        "stock_red_total": value.get("stock_red_total").cloned().unwrap_or(Value::Null),
        "stock_white_remaining": value.get("stock_white_remaining").cloned().unwrap_or(Value::Null),
        "stock_white_total": value.get("stock_white_total").cloned().unwrap_or(Value::Null),
        "consecutive_red": value.get("consecutive_red").cloned().unwrap_or(Value::Null),
    }))
}

fn normalize_predictions_response(value: Value) -> Value {
    let predictions = value
        .get("predictions")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .map(|prediction| {
            json!({
                "date": prediction.get("date").cloned().unwrap_or(Value::Null),
                "predicted_color": prediction.get("predicted_color").cloned().unwrap_or(Value::Null),
                "probabilities": prediction.get("probabilities").cloned().unwrap_or(Value::Null),
                "confidence": rounded_value(prediction.get("confidence")),
                "constraints": prediction.get("constraints").cloned().unwrap_or(Value::Null),
            })
        })
        .collect::<Vec<_>>();

    normalize_json_numbers(json!({
        "success": value.get("success").cloned().unwrap_or(Value::Null),
        "state": value.get("state").map(|state| normalize_state_response(state.clone())).unwrap_or(Value::Null),
        "model_version": value.get("model_version").cloned().unwrap_or(Value::Null),
        "predictions": predictions,
    }))
}

fn normalize_calendar_response(value: Value) -> Value {
    let calendar = value
        .get("calendar")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .filter(|day| !day.get("color").is_some_and(Value::is_null))
        .map(|day| {
            json!({
                "date": day.get("date").cloned().unwrap_or(Value::Null),
                "color": day.get("color").cloned().unwrap_or(Value::Null),
                "is_actual": day.get("is_actual").cloned().unwrap_or(Value::Null),
                "is_prediction": day.get("is_prediction").cloned().unwrap_or(Value::Null),
                "probabilities": day.get("probabilities").cloned().unwrap_or(Value::Null),
                "confidence": rounded_value(day.get("confidence")),
                "constraints": day.get("constraints").cloned().unwrap_or(Value::Null),
            })
        })
        .collect::<Vec<_>>();

    normalize_json_numbers(json!({
        "success": value.get("success").cloned().unwrap_or(Value::Null),
        "season": value.get("season").cloned().unwrap_or(Value::Null),
        "calendar": calendar,
        "statistics": value.get("statistics").cloned().unwrap_or(Value::Null),
        "stock": value.get("stock").cloned().unwrap_or(Value::Null),
    }))
}

fn normalize_history_response(value: Value) -> Value {
    normalize_json_numbers(json!({
        "success": value.get("success").cloned().unwrap_or(Value::Null),
        "count": value.get("count").cloned().unwrap_or(Value::Null),
        "history": value.get("history").cloned().unwrap_or(Value::Null),
    }))
}

fn normalize_calibration_response(value: Value) -> Value {
    json!({
        "success": value.get("success").cloned().unwrap_or(Value::Null),
        "calibrated": value.get("calibrated").cloned().unwrap_or(Value::Null),
        "params": normalize_json_numbers(value.get("params").cloned().unwrap_or(Value::Null)),
    })
}

fn normalize_json_numbers(value: Value) -> Value {
    match value {
        Value::Array(items) => Value::Array(items.into_iter().map(normalize_json_numbers).collect()),
        Value::Object(entries) => Value::Object(
            entries
                .into_iter()
                .map(|(key, value)| (key, normalize_json_numbers(value)))
                .collect(),
        ),
        Value::Number(number) => {
            if let Some(value) = number.as_f64() {
                json!((value * 1_000_000.0).round() / 1_000_000.0)
            } else {
                Value::Number(number)
            }
        }
        other => other,
    }
}

fn rounded_value(value: Option<&Value>) -> Value {
    match value.and_then(Value::as_f64) {
        Some(number) => json!((number * 1_000_000.0).round() / 1_000_000.0),
        None => Value::Null,
    }
}

fn assert_json_eq(left: &Value, right: &Value) {
    assert_eq!(left, right, "left:\n{}\n\nright:\n{}", pretty(left), pretty(right));
}

fn pretty(value: &Value) -> String {
    serde_json::to_string_pretty(value).expect("json should pretty print")
}
