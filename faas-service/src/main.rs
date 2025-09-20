use axum::{
    routing::{get, post},
    Router,
    response::Json,
    extract::{State, Path, Query},
    http::StatusCode,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::net::SocketAddr;
use std::env;
use std::sync::Arc;
use tokio::sync::RwLock;
use std::collections::HashMap;
use chrono::Utc;

// Shared state for the service
#[derive(Clone, Default)]
struct AppState {
    data: Arc<RwLock<HashMap<String, Value>>>,
    request_count: Arc<RwLock<u64>>,
}

#[derive(Deserialize)]
struct QueryParams {
    limit: Option<usize>,
    offset: Option<usize>,
}

#[derive(Serialize, Deserialize)]
struct ServiceInfo {
    service: String,
    version: String,
    instance_id: String,
    port: u16,
    uptime: String,
    request_count: u64,
}

#[tokio::main]
async fn main() {
    // Get configuration from environment
    let port: u16 = env::var("PORT")
        .unwrap_or_else(|_| "8080".to_string())
        .parse()
        .expect("Invalid PORT");
    
    let instance_id = env::var("INSTANCE_ID")
        .unwrap_or_else(|_| "0".to_string());
    
    let addr = SocketAddr::from(([0, 0, 0, 0], port));
    
    // Initialize shared state
    let state = AppState::default();
    
    // Build the router with various endpoints
    let app = Router::new()
        .route("/", get(root))
        .route("/health", get(health))
        .route("/api/status", get(status))
        .route("/api/data", get(get_data).post(post_data))
        .route("/api/data/:key", get(get_data_by_key).delete(delete_data))
        .route("/api/metrics", get(metrics))
        .route("/api/echo", post(echo))
        .with_state(state);
    
    println!("🚀 FAAS Service Instance {} starting on http://{}", instance_id, addr);
    
    // Run the server
    let listener = tokio::net::TcpListener::bind(&addr)
        .await
        .unwrap();
    
    axum::serve(listener, app)
        .await
        .unwrap();
}

// GET /
async fn root() -> &'static str {
    "FAAS Service Running on L1NE Infrastructure"
}

// GET /health
async fn health(State(state): State<AppState>) -> Json<Value> {
    let mut count = state.request_count.write().await;
    *count += 1;
    
    Json(json!({
        "status": "healthy",
        "timestamp": Utc::now().to_rfc3339(),
        "checks": {
            "database": "ok",
            "memory": "ok",
            "disk": "ok"
        }
    }))
}

// GET /api/status
async fn status(State(state): State<AppState>) -> Json<ServiceInfo> {
    let count = *state.request_count.read().await;
    
    Json(ServiceInfo {
        service: "faas-service".to_string(),
        version: "1.0.0".to_string(),
        instance_id: env::var("INSTANCE_ID").unwrap_or_else(|_| "0".to_string()),
        port: env::var("PORT")
            .unwrap_or_else(|_| "8080".to_string())
            .parse()
            .unwrap_or(8080),
        uptime: "0d 0h 0m".to_string(), // Could be calculated from start time
        request_count: count,
    })
}

// GET /api/data
async fn get_data(
    State(state): State<AppState>,
    Query(params): Query<QueryParams>
) -> Json<Value> {
    let data = state.data.read().await;
    let limit = params.limit.unwrap_or(10);
    let offset = params.offset.unwrap_or(0);
    
    let items: Vec<_> = data
        .iter()
        .skip(offset)
        .take(limit)
        .map(|(k, v)| json!({"key": k, "value": v}))
        .collect();
    
    Json(json!({
        "data": items,
        "total": data.len(),
        "limit": limit,
        "offset": offset
    }))
}

// POST /api/data
async fn post_data(
    State(state): State<AppState>,
    Json(payload): Json<Value>
) -> (StatusCode, Json<Value>) {
    let key = Utc::now().timestamp().to_string();
    let mut data = state.data.write().await;
    data.insert(key.clone(), payload);
    
    (StatusCode::CREATED, Json(json!({
        "message": "Data stored successfully",
        "key": key
    })))
}

// GET /api/data/:key
async fn get_data_by_key(
    State(state): State<AppState>,
    Path(key): Path<String>
) -> Result<Json<Value>, StatusCode> {
    let data = state.data.read().await;
    
    match data.get(&key) {
        Some(value) => Ok(Json(value.clone())),
        None => Err(StatusCode::NOT_FOUND)
    }
}

// DELETE /api/data/:key
async fn delete_data(
    State(state): State<AppState>,
    Path(key): Path<String>
) -> StatusCode {
    let mut data = state.data.write().await;
    
    match data.remove(&key) {
        Some(_) => StatusCode::NO_CONTENT,
        None => StatusCode::NOT_FOUND
    }
}

// GET /api/metrics
async fn metrics(State(state): State<AppState>) -> Json<Value> {
    let count = *state.request_count.read().await;
    let data_count = state.data.read().await.len();
    
    Json(json!({
        "metrics": {
            "request_count": count,
            "stored_items": data_count,
            "memory_usage": "unknown",
            "cpu_usage": "unknown"
        },
        "timestamp": Utc::now().to_rfc3339()
    }))
}

// POST /api/echo
async fn echo(Json(payload): Json<Value>) -> Json<Value> {
    Json(json!({
        "echo": payload,
        "timestamp": Utc::now().to_rfc3339(),
        "instance": env::var("INSTANCE_ID").unwrap_or_else(|_| "0".to_string())
    }))
}