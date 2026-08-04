# lumitlab.com

Two Astro sites, both static, both deployed from this repository to Cloudflare Pages.

| Directory   | Domain                | What it is                          |
| ----------- | --------------------- | ----------------------------------- |
| `web/`      | `lumitlab.com`        | Marketing site and the download page |
| `web-docs/` | `docs.lumitlab.com`   | Starlight documentation             |

They are separate Pages projects because a real subdomain needs its own deployment
target. Each is small and builds in about a second.

```bash
cd web && npm install && npm run dev      # http://localhost:4321
```

## Deploying

The domain is already on Cloudflare, so Pages is the path of least resistance: it is
free, has no bandwidth cap, and serves from Cloudflare's CDN.

Create **two** Pages projects, both pointed at this repository:

| Setting            | `lumitlab.com` | `docs.lumitlab.com` |
| ------------------ | -------------- | ------------------- |
| Root directory     | `web`          | `web-docs`          |
| Build command      | `npm run build`| `npm run build`     |
| Output directory   | `dist`         | `dist`              |

Then add the custom domain to each under **Custom domains**. Because the DNS is
already in the same Cloudflare account, the records are created for you.

Pushing to `main` deploys. Pull requests get preview URLs automatically.

## Where the downloads come from

Nothing is hosted here. `web/src/pages/download.astro` asks the GitHub releases API
for the newest release and points the three buttons at its assets:

- `lumit-<version>-windows-x64-setup.exe`
- `lumit-<version>-linux-x64.tar.gz`
- `lumit-<version>-macos-arm64.dmg`

So **tagging a release updates the site with no deploy** — `.github/workflows/release.yml`
builds and publishes on any `v*` tag, and the download page picks it up on next load.
GitHub serves release assets from its own CDN with no bandwidth limit, which is what
every comparable project does; there is nothing to scale here.

If the API call fails or is rate-limited (60 requests/hour per IP, unauthenticated),
every button falls back to the releases page, which is a hard-coded `href` in the
markup. The page is still fully usable with JavaScript disabled.

> **Note.** The macOS `.dmg` in v0.1.0 was not produced by CI — `release.yml` has no
> macOS job (deliberately, see the comment at the top of that file). Future tags will
> not produce one until that job exists or someone runs `packaging/macos/make-dmg.sh`
> by hand and attaches the result.

## Brand

`web/src/components/Wordmark.astro` builds the wordmark out of the app icon on load.
Its "umi" is outlined from the same Schibsted Grotesk the site ships, so the logotype
cannot drift from the body text. `web/public/lumit-wordmark.svg` is the static lockup.

The regeneration script is not checked in; the component is the source of truth. To
change the geometry, edit the keyframes and the `viewBox` anchors directly.
