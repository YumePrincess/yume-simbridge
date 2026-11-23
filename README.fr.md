[English](README.md) · [Français](README.fr.md) · [日本語](README.ja.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md)

<p align="center"><img src="MacApp/SimHubLogo.png" alt="Logo de Yume SIMBridge" width="180"></p>

# Yume SIMBridge

Yume SIMBridge relie un module SIM physique compatible à un Mac ou à un routeur OpenWrt. Le projet réunit les SMS et les appels cellulaires dans un système auto-hébergé, coordonné par un Worker Cloudflare.

## Fonctionnalités

- Application macOS native et interface LuCI pour les routeurs OpenWrt ARM64.
- Connexion USB aux modules cellulaires DJI et Quectel compatibles.
- Boîte de réception et historique SMS, notifications Gotify et automatisation e-mail vers SMS.
- Routage des appels dans les deux sens via Twilio SIP, avec authentification et historique.
- Enregistrements d’appels chiffrés dans le cloud, avec lecture, téléchargement, rétention et suppression.
- Interfaces en anglais, français, japonais, chinois simplifié et chinois traditionnel. La langue du service cloud se règle séparément de la langue du client.

## Prérequis

- **Mac :** Apple Silicon et macOS 26 ou version ultérieure.
- **Routeur :** OpenWrt ARM64 avec LuCI, accès USB au module compatible et paquets audio et Python requis.
- **Services cloud :** compte Cloudflare pour Workers, D1 et R2 ; compte Twilio pour SIP et la téléphonie ; Gotify et Cloudflare Email Routing en option.

## Utiliser Yume SIMBridge

Utilisez le **DMG signé** des GitHub Releases pour installer ou réinstaller l’application Mac. Les Releases ne contiennent pas de ZIP de mise à jour Mac. L’assistant de mise à jour accepte un ZIP signé fourni séparément et vérifie l’identité de signature ainsi qu’un build plus récent.

Pour construire et installer l’application Mac depuis les sources :

```sh
git clone https://github.com/YumePrincess/yume-simbridge.git
cd yume-simbridge
scripts/install-mac.sh --install
```

Branchez le module USB, ouvrez Yume SIMBridge et saisissez l’adresse du Worker ainsi que le jeton client fournis par votre déploiement. Sélectionnez le module, activez le service, puis configurez le routage, l’authentification, les notifications et les enregistrements. L’application inclut Python, PyUSB, libusb et les certificats CA.

Sur OpenWrt, installez l’IPK `luci-app-yume-simbridge` correspondant à votre version, puis ouvrez **Services → Yume SIMBridge** dans LuCI et configurez la même connexion Worker. Lors d’une mise à niveau, l’installateur reprend la configuration et les identifiants du routeur `yume-simhub`.

## Déployer le service cloud

1. Reliez ce dépôt GitHub à l’intégration **Cloudflare Builds** existante. Définissez `Server/` comme répertoire racine et `main` comme branche de production.
2. Configurez la base D1 nommée `yume-simbridge`, le bucket R2 `yume-oss` et la liaison de service `yume-gotify`. Appliquez les migrations SQL de `Server/migrations` via le processus de déploiement avant d’accepter du trafic.
3. Ajoutez les secrets Worker requis : `MASTER_KEY`, `EDGE_TOKEN` et `RECORDING_KEY`. Conservez-les dans le magasin de secrets Cloudflare ; ne les ajoutez pas au dépôt.
4. Définissez les variables propres au déploiement dans `Server/wrangler.jsonc`, notamment `PUBLIC_ORIGIN`, `TWILIO_ACCOUNT_SID`, `TWILIO_NUMBER` et `EMAIL_ADDRESS`. Remplacez chaque valeur d’exemple par les valeurs de vos propres services.
5. Configurez Twilio comme décrit ci-dessous. Pour la réception d’e-mails vers SMS, configurez Cloudflare Email Routing et exigez une vérification DKIM alignée. Configurez Gotify séparément si nécessaire.
6. Enregistrez l’adresse du Worker et `EDGE_TOKEN` dans chaque client. L’application Mac conserve les identifiants et les données d’exécution sous `~/Library/Application Support/YumeSimHub`, avec des permissions réservées au propriétaire ; ce nom de dossier historique est conservé pour les mises à niveau.

Les déploiements Cloudflare passent par l’intégration Cloudflare Builds du dépôt sur `main`. N’inscrivez aucun identifiant dans les fichiers source ou les paquets de publication.

### Configurer Twilio

1. Dans Twilio Console, choisissez un numéro compatible avec les appels. Définissez `TWILIO_ACCOUNT_SID` et `TWILIO_NUMBER` dans la configuration Worker, puis réglez `PUBLIC_ORIGIN` sur l’origine HTTPS publique du Worker.
2. Enregistrez l’Auth Token Twilio dans `.secrets/twilio-token` avec les permissions `0600`. Gardez `.secrets/` privé et hors de Git.
3. Après le déploiement du Worker, lancez le script depuis la racine du dépôt avec le SID, le numéro et l’origine publique :

   ```sh
   TWILIO_ACCOUNT_SID='<Account SID>' TWILIO_NUMBER='<numéro E.164>' PUBLIC_ORIGIN='https://<hôte-worker>' node Server/scripts/configure-twilio.mjs
   ```

   Le script crée ou réutilise une liste d’identifiants SIP, configure `yume-simbridge.sip.twilio.com` et règle l’URL vocale du domaine SIP sur `/twilio/cellular`. Le mot de passe SIP généré et les identifiants des ressources sont enregistrés dans `.secrets/twilio-setup.json`.
4. Après avoir vérifié le Worker, ajoutez `--activate` pour régler l’URL vocale du numéro Twilio sur `/twilio/voice`. Dans les réglages cloud de Yume SIMBridge, saisissez l’Auth Token, le domaine SIP, l’utilisateur `simhub` et le mot de passe généré. L’Auth Token est chiffré dans D1 avec `MASTER_KEY`.

Twilio associe une liste d’identifiants au domaine SIP et utilise l’URL vocale du domaine pour demander les instructions d’appel. Voir [Twilio SIP](https://www.twilio.com/docs/voice/sip) et [Voice webhooks](https://www.twilio.com/docs/usage/webhooks/voice-webhooks).

## Construire les artefacts

Sur un Mac compatible, préparez le runtime embarqué, construisez l’application, puis créez le DMG et le ZIP de mise à jour local :

```sh
scripts/build-mac.sh
python3 -m pip install -r scripts/requirements-dmg.txt
scripts/build-dmg.sh
```

Pour le paquet OpenWrt ARM64 et l’archive routeur, préparez les ressources runtime épinglées puis lancez :

```sh
python3.12 scripts/prepare-runtime.py
openwrt/build.sh
```

Les GitHub Releases incluent le DMG Mac, l’IPK OpenWrt et l’archive routeur avec leurs sommes SHA-256 ; elles omettent le ZIP de mise à jour Mac. Synchronisez la version et le build dans `version.json` et `Server/package.json`.

## Droits d’auteur et licence

Copyright © 2026 **Yume internet LLC**. Le projet est soumis à la **GNU General Public License version 3 uniquement** (`GPL-3.0-only`) ; voir [LICENSE](LICENSE). Les composants disposant de leurs propres avis de licence restent soumis à ces conditions ; consultez les fichiers concernés dans `Mac/`.
