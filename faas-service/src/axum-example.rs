// Simple Axum Web Server Example
use axum::{
    routing::get,
    Router,
    response::Json,
};
use serde_json::json;
use std::net::SocketAddr;
use std::env;

#[tokio::main]
async fn main() {
    // Get port from environment or use default
    let port: u16 = env::var("PORT")
        .unwrap_or_else(|_| "8080".to_string())
        .parse()
        .expect("Invalid PORT");
    
    let addr = SocketAddr::from(([127, 0, 0, 1], port));
    
    // Build the router with simple GET endpoints
    let app = Router::new()
        .route("/", get(root))
        .route("/health", get(health))
        .route("/api/status", get(status))
        .route("/api/data", get(get_data));
    
    println!("Server running on http://{}", addr);
    
    // Run the server using the tokio tcp listener
    let listener = tokio::net::TcpListener::bind(&addr)
        .await
        .unwrap();
    
    axum::serve(listener, app)
        .await
        .unwrap();
}

// GET /
async fn root() -> &'static str {
    "Axum server running via L1NE"
}

// GET /health
async fn health() -> Json<serde_json::Value> {
    Json(json!({
        "status": "healthy",
        "timestamp": chrono::Utc::now().to_rfc3339()
    }))
}

// GET /api/status
async fn status() -> Json<serde_json::Value> {
    let port = env::var("PORT").unwrap_or_else(|_| "unknown".to_string());
    
    Json(json!({
        "service": "axum-api",
        "port": port,
        "version": "1.0.0",
        "instance_id": env::var("INSTANCE_ID").unwrap_or_else(|_| "0".to_string())
    }))
}

// GET /api/data
async fn get_data() -> Json<serde_json::Value> {
    // Simple data response
    Json(json!({
        "data": [
            {"id": 1, "name": "Item 1"},
            {"id": 2, "name": "Item 2"},
            {"id": 3, "name": "Item 3"}
        ],
        "count": 3
    }))
}