# Quartus Prime Lite 17.1 installers

Place these two files here before running `docker build`:

| File | Size | SHA1 |
|------|------|------|
| `QuartusLiteSetup-17.1.0.590-linux.run` | 2 GB | `2b84182836aad9eefe0c8dcd92d052c9778ce887` |
| `cyclonev-17.1.0.590.qdz` | 1.1 GB | `392eebbc61e041be7abd1034de16323a414428e7` |

## How to download

1. Go to:
   https://www.altera.com/downloads/fpga-development-tools/quartus-prime-lite-edition-design-software-version-17-1-linux

2. Under **Individual Files → Quartus Software**, click  
   **"Quartus Prime (includes Nios II EDS)"** → Download  
   Save as: `docker/quartus-installers/QuartusLiteSetup-17.1.0.590-linux.run`

3. Under **Individual Files → Devices**, click  
   **"Cyclone V Device Support"** → Download  
   Save as: `docker/quartus-installers/cyclonev-17.1.0.590.qdz`

4. Build the image:
   ```
   docker build --platform linux/amd64 -t sftm-quartus \
       -f docker/Dockerfile.quartus docker/
   ```
   Or just run `./docker/run-synth.sh` which auto-builds if needed.

## Why not wget/curl?

Intel's CDN (`downloads.intel.com`) blocks automated downloads and requires
cookies set by the license-agreement page. The files must be downloaded via
a browser.
