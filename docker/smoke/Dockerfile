ARG ROCKY_TAG=9
FROM rockylinux:${ROCKY_TAG}

# Minimal end-to-end smoke environment for the cluster-inspector +
# stack-composer + Spack pipeline. Built for a Linux baseline only:
# system gcc, Lmod (via EPEL), Spack from upstream git.

ARG SPACK_REF=v1.1.1

RUN dnf -y install dnf-plugins-core \
 && dnf -y install epel-release \
 && dnf -y --allowerasing install \
        Lmod \
        gcc \
        gcc-c++ \
        gcc-gfortran \
        git \
        make \
        patch \
        which \
        diffutils \
        findutils \
        file \
        bzip2 \
        xz \
        tar \
        gzip \
        unzip \
        curl \
        perl-core \
        python3 \
        python3.11 \
        sudo \
 && dnf clean all \
 && rm -rf /var/cache/dnf

# Spack as a non-root user. Spack's bootstrap and concretize don't
# require root and refuse to write into protected paths cleanly.
RUN useradd --create-home --shell /bin/bash spack \
 && echo "spack ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/spack \
 && chmod 0440 /etc/sudoers.d/spack

# Create the mount points; the runner bind-mounts a persistent host
# directory tree onto /shared, /workspace, and /home/spack/spack/opt
# at run time, so this just gives docker stable directories to attach to.
RUN mkdir -p /shared /workspace \
 && chown -R spack:spack /shared /workspace

USER spack
WORKDIR /home/spack

RUN git clone --depth 1 --branch "${SPACK_REF}" https://github.com/spack/spack.git /home/spack/spack

ENV SPACK_ROOT=/home/spack/spack
ENV PATH=/home/spack/spack/bin:/home/spack/.local/bin:${PATH}

# Source Spack + Lmod in every interactive shell so `module` and
# `spack` Just Work without ceremony.
RUN echo '. /usr/share/lmod/lmod/init/bash' >> /home/spack/.bashrc \
 && echo '. /home/spack/spack/share/spack/setup-env.sh' >> /home/spack/.bashrc

# Run-time bind mounts (from the persistent host runtime dir):
#   /workspace/stack/              the smoke stack tree (profile, stack.yaml, out/)
#   /workspace/cluster-inspector   statically built binary
#   /workspace/stack-composer.pyz  release pyz
#   /workspace/spack-build         spack-build companion script
#   /shared/                       view roots / module roots / buildcache
#   /home/spack/spack/opt          persistent Spack install tree
VOLUME ["/workspace", "/shared", "/home/spack/spack/opt"]

SHELL ["/bin/bash", "-lc"]
CMD ["/bin/bash", "-l"]
