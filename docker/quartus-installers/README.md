# Quartus Prime Lite 21.1.1 installers

Quartus 17.1 (2017) fails on Apple Silicon with `rosetta error: bss_size overflow`
because its BSS segment exceeds Rosetta 2's limits. 21.1.1 (2022) works fine.

Place these two files here before running `docker build`:

| File | Size | SHA1 |
|------|------|------|
| `QuartusLiteSetup-21.1.0.842-linux.run` | 1.7 GB | `(verify after download)` |
| `cyclonev-21.1.0.842.qdz` | 600 MB | `(verify after download)` |

## How to download

1. Go to:
   https://www.altera.com/downloads/fpga-development-tools/quartus-prime-lite-edition-design-software-version-21-1-linux

2. Under **Individual Files → Quartus Software**, click  
   **"Quartus Prime (includes Nios II EDS)"** → Download  
   Save as: `docker/quartus-installers/QuartusLiteSetup-21.1.0.842-linux.run`

3. Under **Individual Files → Devices**, click  
   **"Cyclone V device support"** → Download  
   Save as: `docker/quartus-installers/cyclonev-21.1.0.842.qdz`

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
