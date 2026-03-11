# Fixtures de compatibilite

Ce dossier contiendra les snapshots JSON sanitaires servant a comparer le backend TypeScript actuel et le backend Rust.

## Regles

- jamais de secrets bruts,
- garder la structure JSON exacte,
- documenter la route, la methode et le code HTTP,
- prioriser auth et tempo, puis devices et meross.

## Priorites

### Priorite 1

- `POST /auth/login`
- `POST /auth/verify`
- `GET /tempo`
- `GET /tempo/predictions`
- `GET /tempo/state`

### Priorite 2

- `GET /devices`
- `GET /devices/:deviceId/feeder/status`
- `GET /devices/:deviceId/litter-box/status`
- `GET /devices/:deviceId/fountain/status`
- `GET /meross`
- `GET /meross/:deviceId/status`
