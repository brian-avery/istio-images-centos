#!/bin/bash

set -e

HUB="docker.io/maistra"
DEFAULT_IMAGES="citadel pilot mixer sidecar-injector galley istio-ior proxy-init proxy-init-centos7 proxyv2 istio-must-gather istio-cni prometheus grafana istio-operator"
IMAGES=${ISTIO_IMAGES:-$DEFAULT_IMAGES}
ISTIO_REPO=${ISTIO_REPO:-"https://github.com/Maistra/istio.git"}
ISTIO_BRANCH=${ISTIO_BRANCH:-"maistra-0.12"}

CONTAINER_CLI=${CONTAINER_CLI:-docker}

function usage() {
	[[ -n "${1}" ]] && echo "${1}"

	cat <<EOF
Usage: ${BASH_SOURCE[0]} [options ...]"
	options:
		-t <TAG>    TAG to use for operations on images, required.
		-h <HUB>    Docker hub + username. Defaults to "${HUB}"
		-i <IMAGES> Specify which images should be built
		-b          Build images
		-d          Delete images
		-p          Push images
		-k          Handle bookinfo images in addition to others

At least one of -b, -d or -p is required.

Environment Variables:
  - ISTIO_IMAGES: Specify which images should be built (CLI flag -i takes precedence)
  - ISTIO_REPO: Istio repository URL to clone, when building bookinfo images. Default: ${ISTIO_REPO}
  - ISTIO_BRANCH: Istio repository branch to clone, when building bookinfo images. Default: ${ISTIO_BRANCH}

EOF
exit 2
}

function suffix() {
  if [ "${1}" = "istio-must-gather" -o "${1}" = "proxy-init-centos7" ]; then
    return
  fi

  echo "-ubi8"
}

function build_bookinfo() {
  local dir="$(mktemp -d)"
  git clone --depth=1 -b "${ISTIO_BRANCH}" "${ISTIO_REPO}" "${dir}"

  local src="${dir}/samples/bookinfo/src"

  pushd "${src}/productpage"
    docker build -t "${HUB}/examples-bookinfo-productpage-v1:${TAG}" .
  popd

  pushd "${src}/details"
    #plain build -- no calling external book service to fetch topics
    docker build -t "${HUB}/examples-bookinfo-details-v1:${TAG}" --build-arg service_version=v1 .
    #with calling external book service to fetch topic for the book
    docker build -t "${HUB}/examples-bookinfo-details-v2:${TAG}" --build-arg service_version=v2 --build-arg enable_external_book_service=true .
  popd

  pushd "${src}/reviews"
    #java build the app.
    docker run --rm -v "$(pwd)":/home/gradle/project -w /home/gradle/project gradle:4.8.1 gradle clean build
    pushd reviews-wlpcfg
      #plain build -- no ratings
      docker build -t "${HUB}/examples-bookinfo-reviews-v1:${TAG}" --build-arg service_version=v1 .
      #with ratings black stars
      docker build -t "${HUB}/examples-bookinfo-reviews-v2:${TAG}" --build-arg service_version=v2 --build-arg enable_ratings=true .
      #with ratings red stars
      docker build -t "${HUB}/examples-bookinfo-reviews-v3:${TAG}" --build-arg service_version=v3 --build-arg enable_ratings=true --build-arg star_color=red .
    popd
  popd

  pushd "${src}/ratings"
    docker build -t "${HUB}/examples-bookinfo-ratings-v1:${TAG}" --build-arg service_version=v1 .
    docker build -t "${HUB}/examples-bookinfo-ratings-v2:${TAG}" --build-arg service_version=v2 .
  popd

  pushd "${src}/mysql"
    docker build -t "${HUB}/examples-bookinfo-mysqldb:${TAG}" .
  popd

  pushd "${src}/mongodb"
    docker build -t "${HUB}/examples-bookinfo-mongodb:${TAG}" .
  popd

  rm -rf "${dir}"
}

function exec_bookinfo_images() {
  local cmd="${1}"
  local images="$(docker images | grep -E "${HUB}/examples-bookinfo.*$TAG" | awk "{OFS=\":\"; print \$1, \"$TAG\"}")"
  local image

  for image in ${images}; do
    docker "${cmd}" "${image}"
  done
}

while getopts ":t:h:i:bdpk" opt; do
	case ${opt} in
		t) TAG="${OPTARG}";;
		h) HUB="${OPTARG}";;
		b) BUILD=true;;
		d) DELETE=true;;
		p) PUSH=true;;
		i) IMAGES="${OPTARG}";;
		k) BOOKINFO=true;;
		*) usage;;
	esac
done

[[ -z "${TAG}" ]] && usage "Missing TAG"
[[ -z "${BUILD}" && -z "${DELETE}" && -z "${PUSH}" ]] && usage

if [ -n "${DELETE}" ]; then
	for image in ${IMAGES}; do
		echo "Deleting image ${image}..."
		${CONTAINER_CLI} rmi ${HUB}/${image}$(suffix ${image}):${TAG}
	done

	if [ -n "${BOOKINFO}" ]; then
	  exec_bookinfo_images rmi
	fi
fi

if [ -n "${BUILD}" ]; then
	for image in ${IMAGES}; do
		echo "Building ${image}..."
		${CONTAINER_CLI} build --no-cache -t ${HUB}/${image}$(suffix ${image}):${TAG} -f Dockerfile.${image} .
		echo "Done"
		echo
	done

	if [ -n "${BOOKINFO}" ]; then
	  build_bookinfo
	fi

fi

if [ -n "${PUSH}" ]; then
	for image in ${IMAGES}; do
		echo "Pushing image ${image}..."
		${CONTAINER_CLI} push ${HUB}/${image}$(suffix ${image}):${TAG}
	done

	if [ -n "${BOOKINFO}" ]; then
	  exec_bookinfo_images push
	fi
fi
