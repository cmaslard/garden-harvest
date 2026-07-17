# Runbook — self-hébergement de la base garden-harvest sur le NAS Synology

Checklist des étapes manuelles (DSM, SSH, Cloudflare) qui ne peuvent pas être scriptées
depuis ce repo. À suivre dans l'ordre — chaque phase est une porte : ne pas passer à
la suivante tant que la vérification de la phase courante n'est pas bonne.

Le projet Supabase Cloud (`xygczpwgowmmarfkwdbc`) reste actif et intact pendant tout
le processus — c'est le filet de secours jusqu'à la Phase 6.

---

## Phase 0 — Vérifications sur le NAS

Via DSM (Panneau de configuration → Centre d'informations / Gestionnaire de paquets) et SSH :

- [ ] DSM 7.x installé, **Container Manager** disponible dans le Centre de paquets pour ce modèle exact.
- [ ] Architecture CPU : `uname -m` en SSH.
  - Si `x86_64` : rien de spécial à vérifier.
  - Si ARM (`aarch64`/`armv7`) : avant d'aller plus loin, pour chaque image ci-dessous vérifier qu'un tag `linux/arm64` existe et démarre réellement :
    ```sh
    docker manifest inspect supabase/postgres:17.6.1.136 | grep arm64
    docker manifest inspect supabase/gotrue:v2.189.0 | grep arm64
    docker manifest inspect postgrest/postgrest:v14.12 | grep arm64
    docker manifest inspect supabase/postgres-meta:v0.96.6 | grep arm64
    docker manifest inspect supabase/studio:2026.07.07-sha-a6a04f2 | grep arm64
    docker manifest inspect kong/kong:3.9.1 | grep arm64
    ```
    Si une image bloque ici, chercher un tag alternatif avant de continuer — c'est un vrai bloqueur.
- [ ] RAM libre ≥ 1.5 Go en continu (Moniteur de ressources), en plus de ce que consomment déjà les autres paquets du NAS.
- [ ] Le dossier du projet Docker sera sur un volume normal du NAS (pas un partage USB/externe).

---

## Phase 1 — Stack self-hosted vierge

Sur le NAS (SSH) :

```sh
git clone --depth 1 https://github.com/supabase/supabase /tmp/supabase-upstream
mkdir -p /volume1/docker/garden-harvest-supabase
cp -r /tmp/supabase-upstream/docker/. /volume1/docker/garden-harvest-supabase/
cd /volume1/docker/garden-harvest-supabase
```

- [ ] Remplacer le `docker-compose.yml` copié par [`self-host/docker-compose.yml`](./docker-compose.yml) de ce repo (stack allégée : db, auth, rest, kong, meta, studio).
- [ ] Générer les secrets :
  ```sh
  sh utils/generate-keys.sh
  sh utils/add-new-auth-keys.sh
  ```
- [ ] Copier [`self-host/.env.example`](./.env.example) de ce repo vers `.env` dans ce dossier, et reporter les valeurs générées à l'étape précédente (`POSTGRES_PASSWORD`, `JWT_SECRET`, `ANON_KEY`, `SERVICE_ROLE_KEY`, `DASHBOARD_PASSWORD`, `PG_META_CRYPTO_KEY`).
- [ ] Vérifier que `PGRST_DB_SCHEMAS=garden,public,graphql_public` est bien dans le `.env` final (c'est déjà la valeur par défaut de `.env.example`, mais c'est le point de bug le plus probable si oublié).
- [ ] Ne **jamais** committer ce `.env` nulle part.
- [ ] Démarrer :
  ```sh
  docker compose up -d --wait
  docker compose ps   # db, auth, rest, kong, meta, studio tous "healthy"
  ```
- [ ] Test local :
  ```sh
  curl http://localhost:8000/rest/v1/ -H "apikey: <ANON_KEY>"
  ```
  → doit répondre (pas d'erreur de connexion ni 502 Kong).

**Porte** : ne pas continuer avant que ce test local réponde correctement.

---

## Phase 2 — Rejouer le schéma `garden` + RLS

Sur votre machine (pas le NAS), dans ce repo :

- [ ] Installer la CLI Supabase : `brew install supabase/tap/supabase`
- [ ] Récupérer la connection string du projet cloud : Dashboard Supabase → Project Settings → Database → Connection string (réinitialiser le mot de passe DB si besoin).
- [ ] Dump + restore avec le script fourni :
  ```sh
  cd self-host
  CLOUD_DB_URL="postgresql://postgres:<mdp>@<host-cloud>:5432/postgres" ./migrate.sh dump
  ```
  Les fichiers `roles.sql` / `schema.sql` / `data.sql` sont écrits dans `self-host/dumps/` (déjà ignoré par git — voir `.gitignore`).
- [ ] Ouvrir `self-host/dumps/schema.sql` et jeter un œil aux policies RLS sur `garden.*` — c'est la première fois qu'on les voit en clair, autant vérifier qu'elles correspondent à ce qui est visible dans le dashboard cloud (Auth → Policies).
- [ ] Restaurer sur le self-hosted (voir Phase 1 note sur `db` : aucun port publié par défaut — soit publier temporairement `5432:5432` sur le service `db` le temps de la migration, soit lancer `migrate.sh` depuis un conteneur attaché au même réseau Docker `supabase_default`) :
  ```sh
  SELFHOST_DB_URL="postgresql://postgres:<POSTGRES_PASSWORD>@<nas-ip>:5432/postgres" ./migrate.sh restore
  ```

**Porte** : `garden.products/locations/harvests/profiles` et `garden.harvests_view` existent côté self-host.

---

## Phase 3 — Comptes utilisateurs

- [ ] Vérifier les comptages et policies :
  ```sh
  CLOUD_DB_URL="..." SELFHOST_DB_URL="..." ./migrate.sh verify
  ```
- [ ] `auth.users` doit avoir le même nombre de lignes cloud vs self-host.
- [ ] Si `data.sql` échoue à la restauration à cause d'une dérive de version Postgres/GoTrue entre cloud et self-host : ouvrir `self-host/dumps/data.sql`, repérer les lignes en erreur, les corriger à la main (le volume de données est petit, c'est gérable).

**Porte** : login réel réussi (Phase 4) avec un compte existant et son vrai mot de passe.

---

## Phase 4 — Vérification de bout en bout en local (LAN uniquement)

- [ ] Faire une copie **non commitée** de `index.html` (ex. `index.local-test.html`), y remplacer `SUPABASE_URL` par `http://<nas-ip>:8000` et la clé anon par le nouvel `ANON_KEY`.
- [ ] L'ouvrir depuis un appareil sur le même réseau que le NAS (`python3 -m http.server` ou double-clic direct).
- [ ] Se connecter avec un compte réel migré.
- [ ] Vérifier la lecture de la liste des récoltes (`harvests_view`).
- [ ] Ajouter une récolte test, vérifier qu'elle apparaît, puis la supprimer.
- [ ] Vérifier que les listes déroulantes Produit/Lieu se peuplent (sinon vérifier les `GRANT` sur `garden.*` pour `anon`/`authenticated` : `\dp garden.*` en psql).
- [ ] Supprimer le fichier de test local une fois fini.

**Porte** : roundtrip complet (login + lecture + écriture) OK en LAN avant de toucher au réseau public.

---

## Phase 5 — Exposition publique via Cloudflare Tunnel

`cmaslard.xyz` est déjà délégué à Cloudflare (nameservers `*.ns.cloudflare.com`) — pas besoin d'ouvrir de port routeur ni de gérer de certificat côté DSM.

- [ ] Sur le NAS, ajouter un conteneur `cloudflared` (image `cloudflare/cloudflared:latest`) sur le même réseau Docker que `kong` (réseau `supabase_default` créé par le compose de la Phase 1), avec pour cible interne `http://kong:8000`.
- [ ] Dans le dashboard Cloudflare Zero Trust → Networks → Tunnels : créer un tunnel, récupérer son token, l'utiliser dans la config du conteneur `cloudflared`.
- [ ] Ajouter un **Public Hostname** sur le tunnel : `supabase.cmaslard.xyz` → `http://kong:8000`. Cloudflare crée automatiquement le CNAME et gère le certificat TLS.
- [ ] Ne jamais exposer le port Postgres (5432) via le tunnel ou ailleurs sur internet — seul `kong` (8000) doit être joignable publiquement.
- [ ] Depuis un réseau externe (4G du téléphone) :
  ```sh
  curl https://supabase.cmaslard.xyz/rest/v1/ -H "apikey: <ANON_KEY>"
  ```

**Porte** : réponse correcte depuis l'extérieur du LAN, pas de timeout/523/526.

---

## Phase 6 — Bascule finale

- [ ] Dans `.env` (self-hosted), mettre à jour `SUPABASE_PUBLIC_URL`, `API_EXTERNAL_URL` et `SITE_URL` avec l'URL publique définitive (`https://supabase.cmaslard.xyz` / `https://cmaslard.xyz/garden-harvest/`), puis `docker compose up -d --wait` pour appliquer.
- [ ] Dans `index.html` du repo principal : remplacer `SUPABASE_URL` et la clé anon par les valeurs self-hosted (commit séparé).
- [ ] Redéployer le site (mécanisme actuel inconnu depuis ce repo — à faire manuellement).
- [ ] Tester en prod : login, lecture, écriture test (puis suppression).
- [ ] Prévenir les utilisateurs existants qu'une reconnexion sera nécessaire (nouveau `JWT_SECRET` → sessions cloud invalidées, mais mots de passe inchangés).
- [ ] Garder le projet Supabase Cloud actif quelques jours/semaines comme rollback (revert du commit `index.html` suffit).
- [x] Sauvegarde : couverte par Hyper Backup existant sur `volume2` (Btrfs, snapshots — cohérent pour la donnée Postgres vivante dans `volumes/db/data`, équivalent à une coupure de courant propre pour Postgres au redémarrage). Pas de job `pg_dump` séparé nécessaire.

---

## Pense-bête sécurité

- Postgres (5432) : jamais exposé à internet, ni directement ni via tunnel.
- `.env` (secrets réels) : jamais commité.
- `self-host/dumps/` (dump contenant potentiellement des données réelles + hash de mots de passe) : jamais commité — vérifier qu'il est bien dans `.gitignore`.
- Connection strings cloud/self-host : toujours passées par variable d'environnement au shell, jamais en argument de commande visible dans l'historique, jamais collées dans un fichier suivi par git.
