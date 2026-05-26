# ITG Online TLS Pin Rotation and Signed Security Override

Ce document explique le role de `Save/ITGOnlineNetworkSecurity.ini`, son mode
de verification, et la procedure de rotation TLS en production.

## Resume executif

- Le fichier `Save/ITGOnlineNetworkSecurity.ini` **n'est pas genere
  automatiquement** par le client.
- Ce fichier est un **override d'urgence** pour changer rapidement:
  - les pins TLS (`http_public_key_pins`)
  - la allowlist d'hotes (`http_allow_hosts`)
- L'override n'est applique que si sa signature
  `Save/ITGOnlineNetworkSecurity.ini.sig` est valide.
- Si le fichier ou la signature est invalide, le client conserve son fallback
  interne compile (comportement safe-by-default).

## Pourquoi ce mecanisme existe

Sans override dynamique, une rotation de cle publique TLS cote serveur peut
casser tous les clients pinnes jusqu'a publication d'un nouveau build.

L'override signe permet:

1. une correction rapide sans recompilation du client,
2. une verification cryptographique du contenu distribue,
3. un rollback propre si un pinset est mauvais.

## Sources de verite, ordre de priorite

Au demarrage, le client construit sa politique reseau dans cet ordre:

1. **Pins built-in**:
   - `ITGMANIA_HTTP_PUBLIC_KEY_PINS_DEFAULT`
   - `ITGMANIA_HTTP_PUBLIC_KEY_PINS_BACKUP_DEFAULT`
2. **Override signe** (`Save/ITGOnlineNetworkSecurity.ini` + `.sig`), si valide.
3. **Preference locale** `HttpPublicKeyPins` (persisted setting), utilisee comme
   valeur active apres chargement.

En cas de signature invalide de l'override signe:

- l'override est ignore,
- le client journalise l'erreur,
- il conserve la politique precedente (built-in / preference).

## Fichiers concernes

- Override:
  - `Save/ITGOnlineNetworkSecurity.ini`
  - `Save/ITGOnlineNetworkSecurity.ini.sig`
- Cles de verification cote client:
  - `Data/public.rsa`
  - `Data/keys/*` (cles alternatives pour rotation/transition)

## Format du fichier `.ini`

Seules ces cles sont interpretees:

- `http_public_key_pins`
- `http_allow_hosts`

Exemple minimal:

```ini
http_public_key_pins=itgonline.fr=<sha256_spki_hex>,*.itgonline.fr=<sha256_spki_hex>
http_allow_hosts=itgonline.fr,*.itgonline.fr,*.groovestats.com,*.itgmania.com
```

Points importants:

- Une ligne = `cle=valeur`
- Les lignes vides/commentaires (`#` ou `;`) sont ignorees
- Les espaces autour de `=` sont toleres
- Plusieurs pins pour un meme host sont autorises (liste separee par virgule)

## Format des pins

Chaque entree de `http_public_key_pins` suit:

`host_pattern=sha256_spki_hex`

Exemples:

- `itgonline.fr=<hex64>`
- `*.itgonline.fr=<hex64>`

Un host est valide si **au moins un** pin associe matche le certificat presente.

## Signature: ce qui est verifie

Le client verifie la signature `.sig` avant d'appliquer le fichier `.ini`.

La verification utilise les cles RSA de confiance (`Data/public.rsa`, puis
`Data/keys/*` en fallback), via le mecanisme crypto interne (`CryptManager`).

Consequence operationnelle:

- un fichier modifie sans signature valide est ignore,
- un fichier partiellement distribue (ini sans sig ou inversement) est ignore.

## Procedure de rotation recommandee (zero coupure)

### Etape 1 - Preparer le nouveau pin

Recuperer le SPKI SHA-256 de la nouvelle cle publique serveur:

```bash
openssl s_client -servername itgonline.fr -connect itgonline.fr:443 </dev/null 2>/dev/null \
  | openssl x509 -pubkey -noout \
  | openssl pkey -pubin -outform DER 2>/dev/null \
  | openssl dgst -sha256
```

Normaliser en hex minuscule sans prefixe.

Important: le build source ne contient pas de pin de secours par defaut tant
que `ITGMANIA_HTTP_PUBLIC_KEY_PINS_BACKUP_DEFAULT` reste vide. Le pin de
secours doit venir d'une vraie cle publique standby. Ne pas reutiliser le pin
courant comme "backup": cela ne protege pas une rotation de cle.

### Etape 2 - Publier en mode dual-pin

Avant bascule certificat, distribuer un override signe contenant:

- pin courant
- pin suivant

pour `itgonline.fr` et `*.itgonline.fr`.

### Etape 3 - Basculer le certificat serveur

Changer le certificat/couple de cle cote infra.

Les clients qui ont recu l'override dual-pin continueront de se connecter.

### Etape 4 - Nettoyage post-rotation

Apres fenetre de stabilisation:

- retirer l'ancien pin de l'override,
- ou republier un build avec nouveau pin built-in,
- puis retirer l'override si non necessaire.

## Rollback

Si le nouveau pin est mauvais:

1. republier rapidement un override signe avec l'ancien pin valide,
2. verifier les connexions client,
3. corriger la source cert/infra,
4. republier un override propre.

Le rollback ne demande pas de rebuild client si la chaine de signature est saine.

## Verification terrain (checklist)

1. Le fichier `Save/ITGOnlineNetworkSecurity.ini` existe.
2. Le fichier `Save/ITGOnlineNetworkSecurity.ini.sig` existe.
3. Les logs client ne montrent pas d'erreur de verification de signature.
4. Les connexions HTTPS/WSS vers `itgonline.fr` et `ws.itgonline.fr` passent.
5. Les hosts hors allowlist sont toujours bloques.

## Ce que ce mecanisme ne fait pas

- Il ne desactive pas le TLS pinning.
- Il ne remplace pas la gestion de certificats serveur.
- Il ne dispense pas de publier un nouveau build si vous voulez supprimer une
  dependance historique ou faire tourner la cle de confiance client.

## Gouvernance recommandee

- Garder la cle privee de signature hors des postes utilisateurs (HSM/KMS ou
  machine offline).
- Restreindre qui peut signer/publier.
- Journaliser chaque publication (date, auteur, hash du payload, raison).
- Tester la rotation en staging avant prod.

## Exemple de fichier

Un exemple versionnable est fourni ici:

- `Docs/examples/ITGOnlineNetworkSecurity.ini.example`
