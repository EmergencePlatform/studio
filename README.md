# studio

## Project integration

### Via studio base image

This method provides the quickest startup time as in recommended in most cases.

Create a `script/studio` launcher script:

```bash
#!/bin/bash

export HAB_DOCKER_STUDIO_IMAGE="ghcr.io/emergenceplatform/studio:latest"
hab studio enter -D
```

### Via .studiorc

This method is most compatible with normal use of Habitat studios.

Begin your project's `.studiorc` with:

```bash
#!/bin/bash

hab pkg install emergence/studio
source "$(hab pkg path emergence/studio)/studio.sh"
```

## Development workflow

1. Upload habitat package and do not promote to stable
2. Edit project's `.studiorc` to temporarily use the absolute identifier of the uploaded pre-stable package
