# Futures features ITG Online

Ce fichier sert de registre léger pour les fonctionnalités retenues mais non
planifiées immédiatement. Chaque section doit rester actionnable: objectif,
architecture cible, étapes de mise en place, risques et critères de validation.

## Chat vocal de salon avec LiveKit

### Objectif

Permettre aux joueurs présents dans un même salon ITG Online de communiquer en
vocal temps réel, sans mélanger la voix avec le WebSocket de jeu existant.

Le WebSocket Laravel actuel reste réservé aux événements métier: salon, ready,
sélection de musique, score live, état de partie, invitations, présence. La voix
doit passer par un sous-système WebRTC séparé, afin d'éviter de fragiliser le
flux gameplay.

### Décision technique proposée

Utiliser LiveKit comme SFU WebRTC.

LiveKit peut être utilisé en deux modes:

- LiveKit Cloud: infrastructure managée, plus rapide à tester, mais dépendance
  externe et coût potentiel.
- LiveKit self-hosted: serveur LiveKit déployé sur notre infrastructure, plus
  cohérent avec le contrôle actuel du projet, mais nécessite TLS, UDP, TURN/STUN
  et monitoring.

Pour ce projet, la cible long terme recommandée est self-hosted, avec un
prototype temporaire possible via LiveKit Cloud si on veut valider vite l'UX.

### Architecture cible

```text
ITGmania client
  |
  | HTTP auth / room / score
  v
Laravel API ITG Online
  |
  | generates short-lived LiveKit room token
  v
LiveKit server
  |
  | WebRTC audio
  v
Other ITGmania clients in same room
```

Le serveur Laravel reste l'autorité:

- seul un membre actif du salon peut obtenir un token vocal;
- le token est limité au salon courant;
- le token expire rapidement;
- quitter le salon doit couper la session voix côté client;
- une expulsion ou fermeture de salon doit rendre impossible le renouvellement.

Nom de room LiveKit recommandé:

```text
itg-room-{room_id}
```

Identité LiveKit recommandée:

```text
user:{user_id}
```

Metadata recommandée:

```json
{
  "display_name": "itg_player1_test",
  "room_id": 123,
  "device_name": "itgmania-client-p1"
}
```

### Étapes serveur Laravel

1. Ajouter la configuration LiveKit dans `server/config/itgmania.php` ou un
   fichier dédié:

   ```env
   ITGMANIA_LIVEKIT_ENABLED=false
   ITGMANIA_LIVEKIT_WS_URL=wss://voice.itgonline.fr
   ITGMANIA_LIVEKIT_API_KEY=
   ITGMANIA_LIVEKIT_API_SECRET=
   ITGMANIA_LIVEKIT_TOKEN_TTL_SECONDS=300
   ```

2. Ajouter un endpoint API authentifié:

   ```text
   POST /api/v1/rooms/{room}/voice-token
   ```

3. Vérifications obligatoires côté endpoint:

   - utilisateur authentifié;
   - email vérifié;
   - token API avec capacité joueur normale;
   - utilisateur membre actif du salon;
   - salon non fermé;
   - utilisateur non expulsé;
   - option voix activée côté config.

4. Générer un JWT LiveKit court avec permissions minimales:

   - `roomJoin: true`;
   - `room: itg-room-{room_id}`;
   - `canPublish: true`;
   - `canSubscribe: true`;
   - pas d'admin room;
   - pas d'egress/ingress/recording.

5. Réponse API recommandée:

   ```json
   {
     "enabled": true,
     "ws_url": "wss://voice.itgonline.fr",
     "room": "itg-room-123",
     "token": "...",
     "expires_in": 300
   }
   ```

6. Ajouter des événements d'audit:

   - `voice.token_issued`;
   - `voice.token_denied`;
   - `voice.config_disabled`;
   - `voice.member_not_in_room`.

7. Ajouter des tests:

   - membre actif obtient un token;
   - non membre reçoit 403/404 selon la politique de non-discovery;
   - salon fermé refuse;
   - utilisateur expulsé refuse;
   - feature flag disabled retourne `enabled=false` sans token;
   - le JWT ne donne accès qu'à `itg-room-{room_id}`.

### Étapes infrastructure

1. Déployer LiveKit derrière un domaine séparé, par exemple:

   ```text
   voice.itgonline.fr
   ```

2. Prévoir TLS valide.

3. Ouvrir les ports nécessaires au WebRTC:

   - TCP pour signaling WebSocket HTTPS;
   - UDP pour media WebRTC;
   - TURN si certains réseaux bloquent l'UDP direct.

4. Ajouter monitoring:

   - service LiveKit up/down;
   - nombre de rooms;
   - nombre de participants;
   - erreurs de connexion;
   - CPU/RAM;
   - bande passante;
   - latence/jitter/packet loss si exposés.

5. Ajouter une procédure de restart sans couper les parties autant que possible.

6. Si plusieurs instances deviennent nécessaires, prévoir Redis côté LiveKit.

### Étapes client ITGmania

Le plus gros risque est côté client natif. Ce n'est pas une simple modification
Lua.

Fonctions attendues:

- rejoindre automatiquement le vocal quand le joueur rejoint un salon;
- quitter automatiquement le vocal quand le joueur quitte le salon;
- mute micro;
- deafen local;
- push-to-talk configurable;
- volume des autres joueurs;
- indicateur "parle actuellement";
- état de connexion vocal: connecté, reconnecting, erreur;
- sélection périphérique micro si possible;
- respect des permissions micro macOS;
- aucun blocage du gameplay si le vocal échoue.

Approche recommandée:

1. Prototype externe:

   - petite page web ou client séparé;
   - token généré par Laravel;
   - validation que deux joueurs dans un salon peuvent parler.

2. Prototype natif isolé:

   - intégrer un SDK LiveKit/WebRTC dans une branche dédiée;
   - prouver capture micro + playback audio dans ITGmania;
   - mesurer CPU et latence.

3. Intégration UI minimale:

   - bouton voice on/off dans le salon;
   - icônes mute/deafen;
   - indicateur voix à côté des joueurs.

4. Intégration gameplay prudente:

   - pas d'overlay lourd pendant une chanson;
   - pas de pop-up bloquante;
   - voix dégradée silencieusement si la connexion échoue.

### Règles UX proposées

- Par défaut: vocal activé automatiquement uniquement si l'utilisateur l'a
  accepté dans les préférences.
- Première utilisation: demander confirmation claire.
- Push-to-talk recommandé par défaut pour éviter les micros ouverts.
- Le joueur doit pouvoir couper la voix sans quitter le salon.
- Les erreurs vocales ne doivent jamais empêcher de jouer.
- Le manager ne doit pas être responsable de connecter les joueurs à la voix.

### Risques

- Packaging macOS plus complexe avec WebRTC/LiveKit natif.
- Permissions micro macOS.
- Latence ou jitter audio sur certains réseaux.
- TURN obligatoire pour certains joueurs.
- Coût si LiveKit Cloud.
- Surface réseau supplémentaire.
- Risque de crash si la pile audio/WebRTC est intégrée trop profondément dans
  le thread gameplay.

### Critères d'acceptation

- Deux clients dans le même salon s'entendent avec moins de 300 ms de latence
  perceptible.
- Un joueur dans un autre salon ne peut pas rejoindre la room vocale.
- Quitter le salon coupe la voix.
- Une expulsion coupe ou empêche le renouvellement de la voix.
- Une perte réseau voix ne casse pas le WebSocket de jeu.
- Une perte réseau jeu quitte/neutralise la voix selon l'état salon.
- Le gameplay reste fluide avec la voix active.
- Le build `.app` fonctionne sur Apple Silicon avec permissions micro propres.

### Décision actuelle

Statut: retenu comme future feature, non implémenté.

Raison du report: la valeur produit est réelle, mais l'intégration native audio
WebRTC demande une phase de prototype dédiée. Le serveur Laravel peut être prêt
rapidement, mais l'expérience ne doit pas être livrée tant que le client natif
n'est pas stable.

## Gestion des packs de chansons depuis une borne

### Objectif

Permettre à un exploitant de borne arcade ou d'événement d'importer ou de retirer
des packs de chansons sans clavier, souris, internet ou ordinateur externe.

### Décision technique proposée

Commencer par une approche locale USB, désactivée par défaut et accessible
uniquement depuis le menu opérateur.

Créer un menu opérateur dédié, par exemple `Song Management`, avec deux actions:

- `Import packs`
- `Delete packs`

L'import doit utiliser une préférence dédiée, par exemple `ImportSongsPath`,
pointant vers un chemin local ou une clé USB montée:

- Linux: `/mnt/usb`
- Windows: `Z:\`
- macOS: `/Volumes/<drive>`

Structure attendue sur le support externe:

```text
<ImportSongsPath>/
  Packs/
    Pack A/
    Pack B.zip
```

Le menu d'import doit lister un pack par entrée, avec une option `All` pour tout
importer.

### Flux d'import robuste

1. Scanner uniquement `ImportSongsPath/Packs`.
2. Afficher les packs détectés.
3. Copier le pack sélectionné vers un dossier temporaire.
4. Valider le contenu avant installation.
5. Déplacer atomiquement le pack validé vers `/Songs`.
6. Recharger la liste des chansons.
7. Écrire un log clair pour chaque étape.

### Suppression de packs

Le menu `Delete packs` doit lister uniquement les packs visibles dans `/Songs`.

La suppression doit être protégée:

- confirmation obligatoire;
- idéalement déplacement vers une quarantaine ou une corbeille interne;
- log de l'opération;
- aucune suppression silencieuse.

### Position sur l'approche distante

Ne pas réutiliser `ContentServerURL` comme chemin d'import USB. Un chemin local et
une URL distante n'ont pas les mêmes contraintes, erreurs, permissions et risques.

Si une source distante est ajoutée plus tard, elle doit utiliser une préférence
séparée, par exemple:

- `ImportSongsPath` pour USB/local;
- `RemoteSongsCatalogURL` ou `PackCatalogURL` pour un catalogue serveur.

### Risques

- Path traversal dans les archives zip (`../`, chemins absolus).
- Symlinks malveillants.
- Zip bombs ou archives trop volumineuses.
- Fichiers trop nombreux.
- Collision avec un pack déjà installé.
- Pack incomplet ou simfiles invalides.
- Permissions système incohérentes selon Windows, Linux et macOS.
- Gel du jeu pendant la copie ou le reload.
- Suppression accidentelle si la confirmation est trop faible.

### Critères d'acceptation

- L'import ne lit jamais hors de `ImportSongsPath/Packs`.
- Une archive contenant un chemin dangereux est refusée.
- Un pack importé est installé atomiquement dans `/Songs`.
- Un échec d'import laisse le dossier `/Songs` dans son état précédent.
- Le reload des chansons se déclenche après import réussi.
- La suppression demande une confirmation explicite.
- Chaque import, refus, erreur et suppression est écrit dans les logs.
- La fonctionnalité reste désactivée par défaut.

### Décision actuelle

Statut: retenu comme future feature, non implémenté.

Raison du report: la valeur arcade est claire, mais l'import USB touche au
système de fichiers et doit être livré avec validation stricte, logs et garde-fous
anti-suppression accidentelle.
