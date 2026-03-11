# Plan de portage backend vers Rust

## Objectif

Porter progressivement le backend actuel vers Rust en gardant le frontend React quasiment intact.

Le resultat cible est un service unique en Rust qui :

- expose une API HTTP compatible avec le backend Elysia actuel,
- remplace le serveur Python Tempo,
- remplace progressivement les integrations Meross et Tuya,
- peut ensuite etre deploye sur la STB,
- garde le BLE hors scope initial et le traite en derniere etape.

## Stack cible

- API HTTP : `axum`
- Async runtime : `tokio`
- Serialization : `serde`
- HTTP client : `reqwest`
- JWT : `jsonwebtoken`

## Principes de migration

- Garder le contrat HTTP stable pour ne pas casser le frontend.
- Avancer par phases courtes, testables et validables.
- Porter d'abord les briques les plus isolees.
- Conserver autant que possible les fichiers de configuration et de cache existants.
- Garder le BLE comme module optionnel et tardif.

## Phases

### Phase 0 - Geler le contrat existant

- inventorier les routes exposees,
- identifier les formats JSON a conserver,
- lister les fichiers d'etat local,
- preparer des fixtures de compatibilite,
- definir la checklist de parite TS -> Rust.

### Phase 1 - Squelette Rust minimal

- creer le workspace,
- mettre en place `axum`, config, logs, CORS, erreurs,
- implementer `/`, `/health`, `/auth/login`, `/auth/verify`.

### Phase 2 - Tempo donnees publiques

- porter RTE public + tarifs data.gouv,
- reproduire cache et TTL,
- conserver les memes champs JSON.

### Phase 3 - Port complet du moteur Tempo Python

- porter prediction, etat, historique, calendrier, calibration,
- supprimer la dependance Python.

### Phase 4 - Meross

- porter le client HTTP local,
- reproduire signatures et endpoints actuels.

### Phase 5 - Tuya lecture seule

- porter chargement devices et parseurs,
- reexposer les endpoints de lecture et de stats.

### Phase 6 - Tuya controle et reconnexion

- porter les commandes,
- reimplementer retries, heartbeat, timeouts et reconnexion.

### Phase 7 - Bascule applicative

- brancher le frontend sur le backend Rust,
- supprimer progressivement Bun du chemin critique.

### Phase 8 - Portage STB

- confirmer la cible de compilation,
- produire un binaire adapte,
- integrer le lancement au boot.

### Phase 9 - BLE optionnel

- choisir la strategie BLE finale,
- l'integrer derriere une feature optionnelle.
