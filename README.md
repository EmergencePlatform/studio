# studio

Begin your project's `.studiorc` with:

```bash
#!/bin/bash

hab pkg install emergence/studio
source "$(hab pkg path emergence/studio)/studio.sh"
```

## Development workflow

1. Upload habitat package and do not promote to stable
2. Edit project's `.studiorc` to temporarily use the absolute identifier of the uploaded pre-stable package
