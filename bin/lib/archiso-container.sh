#!/bin/bash

# Shared container configuration for ArchISO validation and builds.

# Sourced by build and validation entry points.
# shellcheck disable=SC2034
readonly ARCHISO_BUILD_IMAGE='archlinux@sha256:b860afd5823683f7ea389ba5f00d812f4fe55f6f286dea329d2abeefa535e309'
declare -a ARCHISO_CONTAINER=()

select_archiso_container() {
  command -v docker >/dev/null || {
    echo 'docker is required' >&2
    return 1
  }

  if docker info >/dev/null 2>&1; then
    ARCHISO_CONTAINER=(docker)
    return 0
  fi

  command -v sudo >/dev/null || {
    echo 'docker is installed but unavailable to this user, and sudo is missing' >&2
    return 1
  }

  ARCHISO_CONTAINER=(sudo -n docker)
  "${ARCHISO_CONTAINER[@]}" info >/dev/null 2>&1 || {
    echo 'docker is unavailable through both the current user and passwordless sudo' >&2
    return 1
  }
}
