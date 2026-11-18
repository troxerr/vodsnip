# Windows code signing (Azure Trusted Signing)

The workflow signs `vodsnip.exe` and the installer when the settings below exist. Without them it builds an unsigned
installer, as before. Nothing else needs to change.

## What you do once (about an hour, mostly waiting on identity checks)

1. **Azure account.** Create one at portal.azure.com with a subscription (pay as you go).
2. **Trusted Signing account.** In the portal, create a *Trusted Signing Account* (the service may now be shown under
   the name Artifact Signing). Pick a region and note its endpoint, e.g. `https://eus.codesigning.azure.net`.
   The Basic plan is about $10/month. Check the current price and which countries qualify for individual
   developers before you start.
3. **Identity validation.** In that account, start *Identity validation* (individual or organization). Microsoft
   checks your ID. Wait until it shows *Completed*.
4. **Certificate profile.** Create a *Public Trust* certificate profile using that identity. Note its name.
5. **Service principal for CI.** In Microsoft Entra ID, register an app, create a client secret, then give that app
   the role **Trusted Signing Certificate Profile Signer** on the signing account.

## Add to GitHub (repo Settings, Secrets and variables, Actions)

Secrets: `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_TENANT_ID` (from the app registration).

Variables: `AZURE_SIGNING_ENDPOINT`, `AZURE_SIGNING_ACCOUNT`, `AZURE_SIGNING_PROFILE`.

Then run the workflow. The step *Signatures are valid* fails the build unless both the installer and the installed
`vodsnip.exe` carry a valid signature.

## Good to know

- SmartScreen reputation is not instant. A signed app with Trusted Signing is treated better than an unsigned one,
  but a brand new publisher can still see a warning for a while.
- The certificate Trusted Signing issues is short-lived, so every signature is timestamped (the tool does this).
  Do not remove the timestamp.
- yt-dlp.exe and ffmpeg.exe are third-party files and stay as their authors ship them.
