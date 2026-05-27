# Cahier des charges - Mode online Feetness / ITGmania

## Objectif

Créer une version moderne d'ITGmania/Feetness avec un mode online intégré.

Le mode online doit permettre aux joueurs de :

- s'inscrire directement depuis le jeu ;
- valider leur compte par email ;
- se connecter depuis le jeu ;
- voir les joueurs connectés ;
- voir les salons publics ;
- inviter des joueurs ;
- créer ou rejoindre des salons ;
- choisir une musique commune ;
- synchroniser le lancement d'une chanson ;
- jouer ensemble ;
- afficher un classement en temps réel.

## Base technique

### Client jeu

- Fork d'ITGmania.
- Moteur principal en C++17.
- Interface, menus et écrans principalement en Lua/theme metrics.
- Communication réseau via WebSocket et API HTTP.

### Serveur

Stack recommandée :

- Laravel ;
- MySQL ;
- WebSocket pour le temps réel ;
- HTTP pour l'API et les transferts de fichiers ;
- Redis plus tard pour la présence, les files et la scalabilité.

Le serveur doit être l'autorité sur les comptes, les salons, les rôles, les invitations, les transitions d'état et le lancement des parties.

## Comptes utilisateurs

### Inscription

L'utilisateur doit pouvoir s'inscrire depuis le jeu avec au minimum :

- pseudo ;
- email ;
- mot de passe.

Après inscription :

- le compte est créé en état non vérifié ;
- le serveur envoie un email de validation ;
- l'utilisateur doit cliquer sur le lien de validation dans son navigateur.

### Validation email

Le lien de validation doit :

- identifier le compte ;
- vérifier un token de validation ;
- expirer après une durée définie ;
- marquer le compte comme validé.

Un compte non validé ne peut pas se connecter au mode online.

### Connexion

Une fois l'email validé, l'utilisateur peut se connecter depuis le jeu.

La connexion retourne :

- un token API ;
- les informations minimales du profil ;
- les informations nécessaires pour ouvrir une connexion WebSocket authentifiée.

## Lobby

Après connexion, l'utilisateur arrive sur un écran online composé de deux colonnes.

### Colonne joueurs connectés

Elle affiche les utilisateurs actuellement connectés.

Chaque entrée peut permettre :

- d'ouvrir une action d'invitation ;
- de voir un statut simple ;
- de savoir si le joueur est disponible, en salon ou en partie.

### Colonne salons

Elle affiche uniquement les salons publics visibles.

Chaque entrée doit afficher au minimum :

- nom du salon ;
- manager ;
- nombre de membres ;
- état du salon ;
- musique sélectionnée si disponible ;
- possibilité de demander à rejoindre.

Les salons privés ne sont pas visibles depuis cette liste.

## Salons

Un salon peut être public ou privé.

Chaque salon contient :

- un identifiant ;
- un nom ;
- une visibilité ;
- un manager ;
- une liste de membres ;
- une liste d'invitations ;
- une liste de demandes d'accès si le salon est public ;
- une chanson sélectionnée ;
- des états de préparation ;
- une phase courante.

## Salons privés

Un salon privé est invisible depuis le lobby public.

Règles :

- personne ne peut demander à rejoindre un salon privé ;
- seuls les membres déjà présents dans le salon peuvent inviter d'autres joueurs ;
- un joueur extérieur ne peut entrer que par invitation ;
- tous les membres peuvent inviter, pas seulement le manager.

Le serveur doit vérifier qu'un utilisateur est membre du salon avant de l'autoriser à envoyer une invitation vers ce salon privé.

## Salons publics

Un salon public est visible dans la liste des salons.

Règles :

- un joueur extérieur peut demander à rejoindre ;
- le manager accepte ou refuse la demande ;
- les membres peuvent aussi inviter directement d'autres joueurs ;
- le serveur reste l'autorité sur les entrées et sorties.

## Manager de salon

Le manager est le joueur qui contrôle les décisions principales du salon.

Le manager peut :

- choisir la chanson finale ;
- accepter ou refuser les demandes d'entrée dans un salon public ;
- transférer son rôle à un autre membre ;
- gérer certaines transitions d'état du salon.

Le manager ne doit pas être une information décidée côté client. Le serveur doit en être l'autorité.

### Transfert du rôle de manager

Le manager peut donner son rôle à un autre membre du salon.

Le serveur doit vérifier que :

- l'utilisateur actuel est bien le manager ;
- le joueur cible est déjà membre du salon ;
- la partie n'est pas dans un état incompatible avec le transfert.

Si le manager quitte le salon sans transférer son rôle, le serveur doit appliquer une règle de succession, par exemple donner le rôle au membre le plus ancien.

## Invitations

Depuis le lobby, un joueur connecté peut inviter un autre joueur.

Cas initial :

- le joueur A invite le joueur B ;
- un salon est créé ;
- A devient manager du salon ;
- B reçoit une invitation en temps réel.

Dans un salon privé :

- seuls les membres actuels peuvent inviter d'autres joueurs.

Dans un salon public :

- les membres peuvent inviter ;
- les non-membres peuvent demander à rejoindre ;
- le manager accepte ou refuse les demandes.

## Choix de musique

Le manager choisit la chanson finale.

Une chanson ne doit pas être identifiée seulement par son nom. Il faut utiliser des identifiants techniques pour éviter les différences de fichiers entre joueurs.

Identifiants recommandés :

- `song_hash` ;
- `chart_hash` ;
- type de chart ;
- difficulté ;
- rate ;
- durée audio ;
- version du format si nécessaire.

Le serveur doit pouvoir savoir quels joueurs possèdent déjà la chanson/chart exacte.

## Transfert de musique

Si le manager choisit une musique que certains joueurs n'ont pas, il peut leur transférer le dossier complet de la musique.

Exemples de fichiers :

- `.sm` ;
- `.ssc` ;
- `.ogg` ;
- `.mp3` ;
- `.png` ;
- `.jpg` ;
- autres fichiers explicitement autorisés.

### Format recommandé

Le transfert doit passer par un package contrôlé, par exemple :

- archive `.zip` ;
- fichier `manifest.json` ;
- hash SHA-256 pour chaque fichier.

Exemple de manifest :

```json
{
  "title": "Song Name",
  "artist": "Artist",
  "folder_name": "Song Folder",
  "files": [
    {
      "path": "song.sm",
      "sha256": "..."
    },
    {
      "path": "music.ogg",
      "sha256": "..."
    },
    {
      "path": "banner.png",
      "sha256": "..."
    }
  ],
  "song_hash": "...",
  "chart_hashes": ["..."]
}
```

### Transport

Le WebSocket ne doit pas transporter les fichiers lourds.

Le flux recommandé est :

1. le manager choisit une chanson ;
2. le serveur détecte quels joueurs ne l'ont pas ;
3. le manager upload le package au serveur via HTTP ;
4. les joueurs concernés téléchargent le package via HTTP ;
5. chaque client vérifie les hashes ;
6. le client installe la chanson localement ;
7. le jeu recharge la liste des chansons ;
8. le joueur peut passer en prêt.

### Sécurité du transfert

Le serveur doit imposer :

- taille maximale ;
- extensions autorisées ;
- refus des fichiers exécutables ;
- refus des chemins absolus ;
- refus des chemins contenant `../` ;
- validation du manifest ;
- vérification des hashes ;
- nettoyage automatique des packages temporaires.

Ce système doit uniquement servir au partage de contenus que les joueurs ont le droit de partager.

## Phases d'un salon

Phases recommandées :

```txt
lobby
song_selection
content_sync
lobby_ready
config
config_ready
starting
playing
results
closed
```

Flux prévu :

1. les joueurs sont dans le salon ;
2. le manager choisit une chanson ;
3. le serveur vérifie que tout le monde possède la chanson ;
4. si nécessaire, les joueurs manquants récupèrent le package ;
5. tous les joueurs se mettent en prêt dans le salon ;
6. quand tout le monde est prêt, le serveur fait basculer tout le monde vers l'écran de configuration ;
7. chaque joueur choisit ses options ;
8. tout le monde se met prêt une seconde fois ;
9. le serveur déclenche le lancement synchronisé ;
10. la chanson démarre chez tous les participants ;
11. les scores sont envoyés au serveur pendant le gameplay ;
12. le serveur diffuse le classement en temps réel ;
13. les résultats finaux sont enregistrés à la fin.

## Synchronisation du lancement

Le serveur doit être l'autorité du départ.

Il ne doit pas envoyer simplement un ordre `start now`. Il doit envoyer un timestamp serveur :

```txt
start_at = server_time + countdown
```

Les clients doivent synchroniser leur horloge avec le serveur via ping/pong WebSocket.

Objectif :

- même chanson ;
- même chart ;
- même configuration de base ;
- départ logique commun.

Une synchronisation parfaite à la frame près n'est pas réaliste sur Internet. Le système doit viser une synchronisation stable et suffisamment précise pour comparer les scores.

## Score en temps réel

Pendant la chanson, chaque client envoie régulièrement son état au serveur.

Données possibles :

- score ;
- combo ;
- accuracy ;
- jugement récent ;
- statut alive/failed ;
- position dans la chanson ;
- timestamp local corrigé.

Fréquence recommandée :

```txt
250ms à 500ms
```

Le serveur calcule ou relaie le classement et le diffuse aux membres du salon.

## Qualité release et validation avant diffusion

Le mode online ajoute du réseau, des overlays temps réel et des transitions synchronisées dans un moteur de jeu de rythme.
Une version qui compile n'est donc pas considérée comme publiable.

Avant toute diffusion publique ou semi-publique d'un build, le projet doit appliquer une discipline de release stricte.

### Gel fonctionnel

Avant une release destinée à des joueurs externes :

- appliquer un gel fonctionnel d'au moins 2 semaines ;
- ne plus merger de nouvelles fonctionnalités pendant cette période ;
- accepter uniquement les corrections de bugs, corrections de crash, corrections de sécurité et corrections de packaging ;
- refuser les refactors larges non indispensables ;
- reporter les mises à jour upstream non critiques après la release.

Une période de tournoi, d'événement public ou de test multi-joueurs important ne doit jamais servir de bêta implicite.

### Builds testés

Les builds testés doivent être produits exactement comme les builds distribués.

Le projet doit distinguer explicitement :

- build local développeur ;
- build CI éventuel ;
- build release ;
- build signé ;
- build notarisé si applicable ;
- build distribué aux testeurs.

Le build distribué aux joueurs doit avoir été validé dans sa forme finale.
Il ne suffit pas de tester une version compilée autrement.

### Tests obligatoires avant release client

Chaque release du jeu doit valider au minimum :

- lancement propre du `.app` final sur une machine propre ;
- connexion online ;
- création de salon ;
- join d'un deuxième joueur ;
- sélection de chanson ;
- passage écran options ;
- retour salon avec états ready ;
- lancement synchronisé ;
- score live en gameplay ;
- fin de chanson ;
- maintien gameplay jusqu'aux états terminaux ;
- écran d'évaluation ;
- retour salon ;
- nouvelle chanson dans le même salon ;
- fermeture brutale du client puis reprise propre ;
- déconnexion réseau temporaire puis resynchronisation.

### Tests longs anti-drift et mémoire

Un jeu de rythme ne peut pas tolérer une dérive progressive du timing.

Avant release, il faut exécuter des tests longs :

- chansons longues ou autoplay d'au moins 10 à 20 minutes ;
- observation de la dérive audio/visuelle ;
- observation du CPU ;
- observation de la mémoire ;
- observation du framerate ;
- observation des logs ;
- vérification que l'overlay online ne crée pas de stutter ;
- vérification que l'envoi de scores ne crée pas de tempête HTTP ;
- vérification que le WebSocket ne provoque pas de fuite mémoire.

Tout nouveau drift de synchronisation, fuite mémoire ou stutter gameplay est bloquant pour une release.

### Testeurs

Les changements moteur, réseau, timing, audio, input, overlay gameplay ou packaging doivent être testés par plusieurs personnes avant diffusion.

Les testeurs doivent recevoir :

- le build final ou un build strictement équivalent ;
- la liste des scénarios à vérifier ;
- les logs à remonter ;
- les conditions de test attendues ;
- une procédure simple pour signaler drift, crash, désynchronisation, freeze ou fuite mémoire.

### Critères bloquants

Une release doit être bloquée si l'un des points suivants est constaté :

- drift audio/notes progressif ;
- fuite mémoire répétable ;
- stutter pendant gameplay ;
- score live incohérent ;
- relance involontaire d'une chanson ;
- transition online bloquée ;
- joueur coincé en salon, options, gameplay ou évaluation ;
- échec de connexion sur le serveur de production ;
- pin TLS invalide ou non testé ;
- build signé refusé par macOS ;
- crash à la fin d'une chanson ;
- logs d'erreur répétés pendant une partie normale.

### Anti-triche

Pour le prototype, le serveur peut faire confiance au client.

Pour un mode compétitif, il faudra renforcer :

- validation des jugements ;
- replay compact ;
- contrôle de cohérence des timings ;
- détection de scores impossibles ;
- signature ou validation des clients si nécessaire.

## Autorité serveur

Le serveur est l'autorité sur :

- identité utilisateur ;
- validation email ;
- sessions ;
- présence ;
- création de salons ;
- visibilité des salons ;
- membres ;
- invitations ;
- demandes d'accès ;
- manager ;
- transfert du rôle de manager ;
- choix final de chanson ;
- états prêt/pas prêt ;
- transitions de phase ;
- lancement synchronisé ;
- classement live officiel.

Le client ne doit jamais pouvoir décider seul :

- qu'il est manager ;
- qu'un joueur est accepté ;
- qu'une partie démarre ;
- qu'une chanson est validée ;
- qu'un salon privé est accessible ;
- qu'un score est officiellement fiable.

## Modèle de données minimal

Tables principales recommandées :

```txt
users
email_verification_tokens
api_tokens

rooms
room_members
room_invitations
room_join_requests

room_song_selection
room_ready_states
song_packages
song_package_files

game_sessions
game_session_players
score_updates
final_scores
```

## Intégration dans ITGmania

Ecrans à ajouter côté jeu :

- inscription ;
- connexion ;
- attente validation email ;
- lobby online ;
- liste des joueurs connectés ;
- liste des salons publics ;
- invitations ;
- demandes d'accès ;
- salon ;
- gestion manager ;
- choix musique online ;
- chanson manquante ;
- téléchargement de package ;
- installation/rechargement chanson ;
- configuration synchronisée ;
- overlay classement live en gameplay ;
- résultats online.

## Ordre de développement recommandé

1. Créer le serveur Laravel.
2. Ajouter inscription + validation email.
3. Ajouter login + token API.
4. Ajouter WebSocket authentifié.
5. Ajouter présence live.
6. Ajouter lobby minimal : joueurs connectés + salons publics.
7. Ajouter création de salons publics/privés.
8. Ajouter invitations.
9. Ajouter demandes d'accès aux salons publics.
10. Ajouter manager + transfert de rôle.
11. Ajouter choix chanson avec hash.
12. Ajouter vérification de disponibilité de chanson côté joueurs.
13. Ajouter transfert de package musique.
14. Ajouter ready phase salon.
15. Ajouter bascule écran configuration.
16. Ajouter ready phase configuration.
17. Ajouter lancement synchronisé.
18. Ajouter score live.
19. Ajouter résultats.
20. Ajouter anti-triche et durcissement sécurité.

## Priorité immédiate

Ne pas commencer par modifier profondément le moteur C++.

La première brique doit être :

```txt
serveur Laravel + auth email + WebSocket + lobby minimal
```

Une fois le serveur stable, connecter ITGmania au serveur via API HTTP et WebSocket.
