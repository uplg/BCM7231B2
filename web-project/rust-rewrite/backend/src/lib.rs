pub mod auth;
pub mod config;
pub mod error;
pub mod meross;
pub mod routes;
pub mod tempo;
pub mod tuya;

use std::sync::Arc;

use axum::Router;
use config::Config;
use error::AppError;
use routes::auth::{load_users, SharedUsers};
use meross::MerossManager;
use tempo::TempoService;
use tuya::TuyaManager;
use tower_http::{cors::CorsLayer, trace::TraceLayer};

#[derive(Clone)]
pub struct AppState {
    pub(crate) config: Arc<Config>,
    pub(crate) users: SharedUsers,
    pub(crate) meross: MerossManager,
    pub(crate) tempo: TempoService,
    pub(crate) tuya: TuyaManager,
}

pub fn app_from_env() -> Result<Router, AppError> {
    let config = Arc::new(Config::from_env());
    build_app_from_config(config)
}

pub fn build_app_from_config(config: Arc<Config>) -> Result<Router, AppError> {
    let users = Arc::new(load_users(&config));
    let meross = MerossManager::new(&config.meross_devices_path)?;
    let tempo = TempoService::new(config.source_root.clone())?;
    let tuya = TuyaManager::new(&config.devices_path, &config.device_cache_path)?;

    let state = AppState {
        config,
        users,
        meross,
        tempo,
        tuya,
    };

    let startup_tuya = state.tuya.clone();
    tokio::spawn(async move {
        let device_ids = startup_tuya
            .list_devices()
            .await
            .into_iter()
            .map(|device| device.id)
            .collect::<Vec<_>>();
        for device_id in device_ids {
            let _ = startup_tuya.connect_device(&device_id).await;
        }
    });

    Ok(build_app(state))
}

pub fn build_app(state: AppState) -> Router {
    let api_router = Router::<AppState>::new()
        .merge(routes::root::router())
        .nest("/auth", routes::auth::router())
        .nest("/devices", routes::devices::router())
        .nest("/meross", routes::meross::router())
        .nest("/tempo", routes::tempo::router());

    Router::<AppState>::new()
        .merge(routes::root::router())
        .nest("/api", api_router)
        .layer(CorsLayer::permissive())
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}
