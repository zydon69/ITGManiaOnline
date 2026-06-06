# Registre des risques assumes - ArrowCloud

## RA-AC-001 - API key ArrowCloud stockee en clair

- Statut: Connu assume
- Owner: mainteneur ITGmania Online / theme Simply Love fork
- Source: `{ProfileDir}/ArrowCloud.ini`, champ `ApiKey`
- Justification: le stockage local en clair suit le modele existant des integrations de score du theme, notamment GrooveStats. Le secret reste scoped au profil local et permet une integration simple avec les profils ITGmania, y compris profils USB.
- Impact: une personne ou un logiciel ayant acces au dossier de profil peut lire la cle ArrowCloud et agir au nom du joueur sur le service.
- Mitigations actuelles: la cle n'est pas loggee; les logs HTTP redigent les champs de type token/secret; l'envoi reseau utilise HTTPS et `Authorization: Bearer`.
- Horizon de sortie: prochaine passe dediee "gestion secrets profil", avec etude d'un stockage chiffrable par OS quand disponible et fallback explicite pour profils portables/USB.
