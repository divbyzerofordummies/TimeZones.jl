# This Dockerfile creates an app using TimeZones and then copies the build directory to a "clean" container without the build dependencies.
# This is to test the re-locatability of the package.
# Provide PACKAGE_NAME to state which package should be tested (this should be used in the Compiling.jl script)
# Provide PACKAGE_BRANCH to state which branch of the branch should be tested

ARG PRECOMPILED
ARG JULIA_VERSION
ARG PACKAGE_NAME
ARG PACKAGE_BRANCH

FROM julia:${JULIA_VERSION}-bullseye AS BASE
SHELL ["/bin/bash", "-c"]

# Create the base image for Compiling. Here you would still have SSH keys for obtaining code from private repositories etc.
FROM BASE as BUILDER

RUN apt-get update
# we need a compiler to use Julia's PackageCompiler
RUN apt-get install build-essential -y

# copy julia project files (only those are needed for re-creating the exact same version in the container)
RUN mkdir /root/package_test
COPY create_app.jl /root/package_test/create_app.jl

RUN mkdir /root/package_test/Compiling
RUN mkdir /root/package_test/Compiling/src
COPY Compiling/src/Compiling.jl /root/package_test/Compiling/src/Compiling.jl
COPY Compiling/Project.toml /root/package_test/Compiling/Project.toml


# build environment
RUN cd /root/package_test; julia --project=. --eval 'import Pkg; Pkg.Registry.update()'
RUN cd /root/package_test; julia --project=. --eval 'import Pkg; Pkg.add("PackageCompiler")'
RUN cd /root/package_test; julia --project=. --eval 'import Pkg; Pkg.develop(path="Compiling")'
RUN cd /root/package_test; julia --project=. --eval 'import Pkg; Pkg.instantiate()'

RUN cd /root/package_test; julia --project=. --eval 'include("create_app.jl")'

# Copy only the compiled app to the base image WITHOUT Julia
FROM debian:bullseye-slim AS main

COPY --from=BUILDER /root/package_test/app /root/package_test/app

COPY entrypoint_app.sh /root/package_test/entrypoint_app.sh
RUN chmod +x /root/package_test/entrypoint_app.sh
ENTRYPOINT /root/package_test/entrypoint_app.sh