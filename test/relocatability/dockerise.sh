#!/bin/bash

JULIA_VERSION=${1:-1.10.5}

echo "Building TimeZones test app..."
docker build --tag timezones_test --file Dockerfile . --build-arg JULIA_VERSION=$JULIA_VERSION --build-arg PACKAGE_NAME=TimeZones --build-arg PACKAGE_BRANCH=master
