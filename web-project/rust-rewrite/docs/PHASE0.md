# Phase 0 - Contrat HTTP et contraintes de migration

## But

Figer ce que le backend Rust devra reproduire pour que le frontend continue de fonctionner sans refonte majeure.

## Synthese rapide

- le frontend appelle `/api/*`,
- le backend actuel expose auth, devices, feeder, litter-box, fountain, meross, tempo et hue-lamps,
- le coeur prioritaire pour la reimplementation initiale est `auth + tempo`,
- le BLE reste explicitement hors du scope initial,
- les fichiers existants `users.json`, `devices.json`, `device-cache.json` et `meross-devices.json` orientent la compatibilite de migration.

## Noyau minimal recommande pour la suite

- `POST /auth/login`
- `POST /auth/verify`
- `GET /tempo`
- `GET /tempo/predictions`
- `GET /tempo/state`

## Fichiers a relire tels quels au debut

- `../cat-monitor/users.json`
- `../cat-monitor/devices.json`
- `../cat-monitor/device-cache.json`
- `../cat-monitor/meross-devices.json`

## Contraintes

- ne pas rendre les payloads plus stricts trop tot,
- conserver les enveloppes `{ success, message?, error? }`,
- garder les routes historiques meme si elles ne sont pas REST parfaites,
- sanitizer toute fixture issue du projet existant.
