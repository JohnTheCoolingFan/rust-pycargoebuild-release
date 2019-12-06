#!/usr/bin/env bash
set -e

function die()
{
    echo "::error::$1"
    echo "------------------------------------------------------------------------------------------------------------------------"
    exit 1
}

function create_pull_request() 
{
    # JSON strings
    src="\"${1}\""		# from this branch
    tgt="\"${2}\""		# pull request TO this target
    body="\"${3}\""		# this is the content of the message
    title="\"${4}\""	# pull request title

    # JSON boolean
    if [[ "${5}" ==  "true" ]]; then
      draft="true";
    else
      draft="false";
    fi

	api_ver="v3"
	base_url="https://api.github.com"
	auth_hdr="Authorization: token ${INPUT_DEPLOY_KEY}"
	header="Accept: application/vnd.github.${api_ver}+json"
	header="${header}; application/vnd.github.antiope-preview+json; application/vnd.github.shadow-cat-preview+json"
	repo_url="${base_url}/repos/${INPUT_OVERLAY_REPO}"
	pulls_url="${repo_url}/pulls"

    # Check if the branch already has a pull request open
    data="{\"base_url\":${tgt}, \"head\":${src}, \"body\":${body}}"
    resp=$(curl -sSL -H "${auth_hdr}" -H "${header}" -X GET --data "${data}" "${pulls_url}")
    echo -e "Raw response:\n${resp}"
    pr=$(echo "${resp}" | jq --raw-output '.[] | .head.ref')
    echo "Response ref: ${pr}"

    if [[ "${pr}" == "${src}" ]]; then
	    # A pull request is already open
        echo "Pull request from ${src} to ${tgt} is already open!"
    else
        # Post new pull request
        data="{\"title\":${title}, \"body\":${body}, \"base_url\":${tgt}, \"head\":${src}, \"draft\":${draft}}"
        echo "curl --user ${GITHUB_ACTOR} -X POST --data ${data} ${pulls_url}"
        curl -sSL -H "${auth_hdr}" -H "${header}" -X POST --data "${data}" "${pulls_url}"
        echo $?
    fi
}

SEMVER_REGEX="^(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*))*$"

[[ ${GITHUB_REF} = refs/heads/* ]] && git_branch="${GITHUB_REF##*/}"
[[ ${GITHUB_REF} = refs/tags/* ]] && git_tag="${GITHUB_REF##*/}"

cat << END
------------------------------------------------------------------------------------------------------------------------
                      _   _                       _           _ _     _                 _                     
                     | | (_)                     | |         (_) |   | |               | |                    
            __ _  ___| |_ _  ___  _ __ ______ ___| |__  _   _ _| | __| |______ _ __ ___| | ___  __ _ ___  ___ 
           / _\` |/ __| __| |/ _ \| '_ \______/ _ \ '_ \| | | | | |/ _\` |______| '__/ _ \ |/ _ \/ _\` / __|/ _ \\
          | (_| | (__| |_| | (_) | | | |    |  __/ |_) | |_| | | | (_| |      | | |  __/ |  __/ (_| \__ \  __/
           \__,_|\___|\__|_|\___/|_| |_|     \___|_.__/ \__,_|_|_|\__,_|      |_|  \___|_|\___|\__,_|___/\___|
 
          https://github.com/hacking-gentoo/action-ebuild-release                         (c) 2019 Max Hacking 
------------------------------------------------------------------------------------------------------------------------
GITHUB_ACTOR=${GITHUB_ACTOR}
GITHUB_REPOSITORY=${GITHUB_REPOSITORY}
GITHUB_REF=${GITHUB_REF}
git_branch=${git_branch}
git_tag=${git_tag}
------------------------------------------------------------------------------------------------------------------------
END

# Check for a GITHUB_WORKSPACE env variable
[[ -z "${GITHUB_WORKSPACE}" ]] && die "Must set GITHUB_WORKSPACE in env"
cd "${GITHUB_WORKSPACE}" || exit 2

# Check for a tag
[[ -z "${GITHUB_REF}" ]] && die "Expecting GITHUB_REF to be a tag"

# Check for github token.
[[ -z "${INPUT_AUTH_TOKEN}" ]] && die "Must set INPUT_AUTH_TOKEN"

# Check for an overlay
[[ -z "${INPUT_OVERLAY_REPO}" ]] && die "Must set INPUT_OVERLAY_REPO"

# Check for repository deploy key.
[[ -z "${INPUT_DEPLOY_KEY}" ]] && die "Must set INPUT_DEPLOY_KEY"

# If there isn't a .gentoo directory in the base of the workspace then bail
[[ -d .gentoo ]] || die "No .gentoo directory in workspace root"

# Find the ebuild to test and strip the .gentoo/ prefix 
# e.g. dev-libs/hacking-bash-lib/hacking-bash-lib-9999.ebuild
ebuild_path=$(find .gentoo -iname '*-9999.ebuild' | head -1)
ebuild_path="${ebuild_path#*/}"
[[ -z "${ebuild_path}" ]] && die "Unable to find a template ebuild"

# Calculate the ebuild name e.g. hacking-bash-lib-9999.ebuild
ebuild_name="${ebuild_path##*/}"
[[ -z "${ebuild_name}" ]] && die "Unable to calculate ebuild name"

# Calculate the ebuild package name e.g. hacking-bash-lib
ebuild_pkg="${ebuild_path%-*}"
ebuild_pkg="${ebuild_pkg##*/}"
[[ -z "${ebuild_pkg}" ]] && die "Unable to calculate ebuild package"

# Calculate the ebuild package category
ebuild_cat="${ebuild_path%%/*}"
[[ -z "${ebuild_cat}" ]] && die "Unable to calculate ebuild category"

# Work out from the tag what version we are releasing.
# e.g. 1.0.0
ebuild_ver="${GITHUB_REF##*/}"
[[ ${ebuild_ver} =~ ${SEMVER_REGEX} ]] || die "Unexpected release version - ${ebuild_ver}"

# Calculate overlay branch name
overlay_branch="${INPUT_OVERLAY_BRANCH:-${ebuild_cat}/${ebuild_pkg}}"

# Display our findings thus far
echo "Located ebuild at ${ebuild_path}"
echo "  in category ${ebuild_cat}"
echo "    for ${ebuild_pkg}"
echo "      version ${ebuild_ver}"
echo "        with name ${ebuild_name}"

# Configure ssh
echo "Configuring ssh agent"
eval "$(ssh-agent -s)"
mkdir -p /root/.ssh
ssh-keyscan github.com >> /root/.ssh/known_hosts
echo "${INPUT_DEPLOY_KEY}" | ssh-add -
ssh-add -l

# Configure git
echo "Configuring git"
git config --global user.name "${GITHUB_ACTOR}"
git config --global user.email "${GITHUB_ACTOR}@github.com"

# Checkout the overlay (master).
echo "Checkout overlay (master)"
overlay_dir="/var/db/repos/action-ebuild-release"
mkdir -p "${overlay_dir}"
cd "${overlay_dir}"
git init
git remote add github "git@github.com:${INPUT_OVERLAY_REPO}.git"
git pull github master 

# Check out the branch or create a new one
echo "Checkout overlay (${overlay_branch})"
git pull github "${overlay_branch}" 2>/dev/null || git branch "${overlay_branch}"
git checkout -b "${overlay_branch}"

# Try to rebase.
echo "Attempting to rebase against master"
git rebase master || true

# Add the overlay to repos.conf
echo "Adding overlay to repos.conf"
repo_name="$(cat profiles/repo_name 2>/dev/null || true)"
[[ -z "${repo_name}" ]] && repo_name="action-ebuild-release"
cat << END > /etc/portage/repos.conf/action-ebuild-release
[${repo_name}]
priority = 50
location = ${overlay_dir}
END

# Ensure that this ebuild's category is present in categories file.
echo "Checking this ebuild's category is present in categories file"
mkdir -p profiles
echo "${ebuild_cat}" >> profiles/categories
sort -u -o profiles/categories profiles/categories

# Copy everything from the template to the new ebuild directory.
echo "Copying ebuild directory"
mkdir -p "${ebuild_cat}/${ebuild_pkg}"
cp "${GITHUB_WORKSPACE}/.gentoo/${ebuild_cat}/${ebuild_pkg}"/* "${ebuild_cat}/${ebuild_pkg}/"

# Create the new ebuild - 9999 live version.
echo "Creating live ebuild"
ebuild_file_live="${ebuild_cat}/${ebuild_pkg}/${ebuild_name}"
unexpand --first-only -t 4 "${GITHUB_WORKSPACE}/.gentoo/${ebuild_path}" > "${ebuild_file_live}" 
sed-or-die "GITHUB_REPOSITORY" "${GITHUB_REPOSITORY}" "${ebuild_file_live}"
sed-or-die "GITHUB_REF" "master" "${ebuild_file_live}"

# Fix up the KEYWORDS variable in the new ebuild - 9999 live version.
echo "Fixing up KEYWORDS variable in new ebuild - live version"
sed -i 's/^KEYWORDS.*/KEYWORDS=""/g' "${ebuild_file_live}"

# Build / rebuild manifests
echo "Rebuilding manifests (live ebuild)" 
ebuild "${ebuild_file_live}" manifest --force

# Create the new ebuild - $ebuild_ver version.
echo "Creating new ebuild"
ebuild_file_new="${ebuild_cat}/${ebuild_pkg}/${ebuild_pkg}-${ebuild_ver}.ebuild"
unexpand --first-only -t 4 "${GITHUB_WORKSPACE}/.gentoo/${ebuild_path}" > "${ebuild_file_new}"
sed-or-die "GITHUB_REPOSITORY" "${GITHUB_REPOSITORY}" "${ebuild_file_new}"
sed-or-die "GITHUB_REF" "master" "${ebuild_file_new}"

# Build / rebuild manifests
echo "Rebuilding manifests (new ebuild)" 
ebuild "${ebuild_file_new}" manifest --force

# If no KEYWORDS are specified try to calculate the best keywords
if [[ -z "$(unstable_keywords "${ebuild_file_new}")" ]]; then
	new_keywords="$(kwtool b "${ebuild_cat}/${ebuild_pkg}-${ebuild_ver}")"
	sed-or-die '^KEYWORDS.*' "KEYWORDS=\"${new_keywords}\"" "${ebuild_file_new}"
fi

# If this is a pre-release then fix the KEYWORDS variable
if [[ $(jq ".release.prerelease" "${GITHUB_EVENT_PATH}") == "true" ]]; then
	new_keywords="$(unstable_keywords "${ebuild_file_new}")"
	sed-or-die '^KEYWORDS.*' "KEYWORDS=\"${new_keywords}\"" "${ebuild_file_new}"
fi

# Build / rebuild manifests
echo "Rebuilding manifests (new ebuild, pass two)" 
ebuild "${ebuild_file_new}" manifest --force

# Add it to git
echo "Adding files to git"
git add .

# Check it with repoman
echo "Checking with repoman"
repoman --straight-to-stable -dx full

# Commit the new ebuild.
echo "Committing new ebuild"
git commit -m "Automated release of ${ebuild_cat}/${ebuild_pkg} version ${ebuild_ver}"

# Push git repo branch
echo "Pushing to git repository"
git push --force --set-upstream github "${overlay_branch}"

# Create a pull request
echo "Creating pull request" 
title="Automated update of ${ebuild_cat}/${ebuild_pkg}"
msg="Automatically generated pull request to update overlay for release of ${ebuild_cat}/${ebuild_pkg}"
create_pull_request "${overlay_branch}" "master" "${msg}" "${title}" "false" 

echo "------------------------------------------------------------------------------------------------------------------------"
