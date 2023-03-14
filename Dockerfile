FROM habitat/default-studio-x86_64-linux:1.6.607

# configure environment
ARG HAB_LICENSE=no-accept
ENV HAB_LICENSE=$HAB_LICENSE
ENV EMERGENCE_REPO=/src

# install dependencies
RUN hab pkg install core/mysql \
    && hab pkg exec core/coreutils -- rm -rf /hab/cache/artifacts/ /hab/cache/src/

# install studio
ARG STUDIO_PKG=emergence/studio
RUN hab pkg install ${STUDIO_PKG} \
    && hab pkg exec core/coreutils -- rm -rf /hab/cache/artifacts/ /hab/cache/src/

# enable loading studio
RUN hab pkg exec core/coreutils -- mv /etc/profile.enter /etc/profile.enter.original \
    && echo $'#!/bin/bash\n\nsource $(hab pkg path emergence/studio)/studio.sh\n\nsource /etc/profile.enter.original' > /etc/profile.enter
