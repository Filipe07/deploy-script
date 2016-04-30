#!/bin/bash

#
# Rsync Deploy
# http://github.com/filipe07
#
# Deploy script designed for a quickly appplication deploy with zero downtime.
# Ideally use for a small application with one server.
#
# Great thanks to "Chauncey Garrett" by inspiration - http://chauncey.io
#
# @filipe07

alias echo="echo -e"

# Get variables
config_file="${PWD}/deploy.conf"
[[ -f ${config_file} ]] && source "${config_file}"


# SSH command
ssh_cmd()
{
	ssh -p "${port}" "${username}"@"${hostname}" -T ${@}
}


# Assign server variables
get-server-variables() {
# Determine the current release version
num_version_last="$(ssh_cmd cat ${path_deploy_to}/last_version)" || exit 30
(( num_version_current = num_version_last+1 ))

# Determine the number of releases
num_releases="$( ssh_cmd "ls -1d ${path_deploy_to}/${dir_deploy_releases}/[0-9]* | sort -rn | wc -l" )" || exit 35
num_releases_remove=$(( ${num_releases} > ${keep_releases} ? ${num_releases} - ${keep_releases} : 0 ))
}


# Init Configurations for deploy
ssh_cmd_init()
{
cat << EOF
echo "$(tput setaf 3;)-----> Setting up ${path_deploy_to}$(tput sgr0;)" &&
(
	mkdir -p $path_deploy_to &&
	echo "0" > ${path_deploy_to}/"last_version" &&
	mkdir -p ${path_deploy_to}/${dir_deploy_cache} &&
	mkdir -p ${path_deploy_to}/${dir_deploy_releases}/0 &&
	chown -R ${dir_deploy_owner}:${dir_deploy_owner} ${path_deploy_to} &&
	chmod -R g+rx,u+rwx ${path_deploy_to} &&
	ls -la ${path_deploy_to} &&
	echo "$(tput setaf 2;)-----> Done$(tput sgr0;)"
) || (
cat <<- EOT
! ERROR: Setup failed.
!
! Ensure that the path ${path_deploy_to} is accessible to the SSH user.
! You may need to run:
!
    sudo mkdir -p ${path_deploy_to} && sudo chown -R ${path_owner} ${path_deploy_to}
!
EOT
)
EOF
}

#Prompt to avoid deploy erros
deploy-prompt()
{
	prompt=$(tput setaf 2; echo 'Do you really want to deploy? (y/n)'; tput sgr0;)

	read -ep "$prompt" yn
	case $yn in
	    [Yy]* ) ;;
	    [Nn]* ) exit 1;;
	    * )

	    echo "Please answer yes(y) or no(n).";
	    deploy-prompt;;
	esac
}


# Rsync cache - Create and update a cache file for faster builds
deploy-rsync-cache()
{
	# Lock
	ssh_cmd_lock | ssh_cmd
	local exit_code=$?
	[[ ${exit_code} != 0 ]] && exit ${exit_code}

	echo "$(tput setaf 3;)-----> Updating cache @ ${username}@${hostname}:${path_deploy_to}/${dir_deploy_cache}$(tput sgr0;)"

	# Base rsync options
	local rsync_options
	rsync_options="-azvruHx --progress --human-readable --stats --delete "

	local rsync_exclude_from=""
	for i in ${path_to_exclude[@]}; do
	   rsync_exclude_from="$rsync_exclude_from --exclude $i "
	done

	rsync ${rsync_options} ${rsync_exclude_from} ${path_deploy_from} ${username}@${hostname}:${path_deploy_to}/${dir_deploy_cache}

	echo "$(tput setaf 3;)-----> Cached.$(tput sgr0;)"
}

deploy-done(){
	echo "$(tput setaf 2;)-----> Done$(tput sgr0;)"
}

# Staging command - Make public
ssh_cmd_stage()
{
cat << EOF
# Sanity checks
[[ ! -f "${path_deploy_to}/last_version" ]] && echo "
! ERROR: Can't determine the last version.
! Ensure that "${path_deploy_to}/last_version" exists and contains the correct version.
! You may need to run: deploy.sh --init
!" && exit 25

# Stage
echo "$(tput setaf 3;)-----> Staging @ ${username}@${hostname}:${path_deploy_to}$(tput sgr0;)"

echo "$(tput setaf 3;)-----> Staged$(tput sgr0;)"
echo "$(tput setaf 3;)-----> Moving build to ${dir_deploy_releases}/${num_version_current}$(tput sgr0;)"
cp -R "${path_deploy_to}/${dir_deploy_cache}/" "${path_deploy_to}/${dir_deploy_releases}/${num_version_current}"

echo "$(tput setaf 3;)-----> Updating the current symlink$(tput sgr0;)"
ln -nfs "${path_deploy_to}/${dir_deploy_releases}/${num_version_current}" "${path_deploy_to}/current"

echo "${num_version_current}" > "${path_deploy_to}/last_version"

echo "$(tput setaf 3;)-----> Deployed.$(tput sgr0;) $(tput setaf 6;)v${num_version_current} is on!$(tput sgr0;)"
EOF
}

#Cleanup old releases
ssh_cmd_cleanup()
{
cat << EOF
echo "$(tput setaf 3;)-----> Cleaning up old releases (keeping ${keep_releases})$(tput sgr0;)"

cd ${path_deploy_to}/${dir_deploy_releases} &&
ls -1d [0-9]* | sort -rn | tail -n ${num_releases_remove} | xargs rm -rf {} || exit 45
EOF
}


# Lock - Prevent simultaneous deployments
ssh_cmd_lock()
{
cat << EOF
# Ensure deploy path is accessible
cd "${path_deploy_to}" || (
  echo "
! ERROR: Not set up.
!
! The path '${path_deploy_to}' is not accessible on the server.
! You may need to run: deploy.sh --init
!"
  false
) || exit 10

# Ensure deploy.sh --init has successfully run
if [ ! -d "${path_deploy_to}/${dir_deploy_releases}" ]
then
  echo "
! ERROR: Not set up.
!
! The directory '${path_deploy_to}/${dir_deploy_releases}' does not exist on the server.
! You may need to run:
!
    deploy.sh --init
!" && exit 15
fi

# Check whether or not another deployment is ongoing
[[ -f "${path_deploy_to}/${lock_file}" ]] &&
	echo "
! ERROR: another deployment is ongoing.
!
! The lock-file '${lock_file}' was found.
! If no other deployment is ongoing, run
!
    deploy.sh unlock|-u
!
! to delete the file and continue." && exit 20

# Lock
touch "${path_deploy_to}/${lock_file}"

echo "$(tput setaf 3;)-----> Locked$(tput sgr0;)"

EOF
}

# Unlock after successful build
ssh_cmd_unlock()
{
cat << EOF
rm -f "${path_deploy_to}/${lock_file}"

echo "$(tput setaf 3;)-----> Unlocked$(tput sgr0;)"
EOF
}


# Rollback to the previous release
ssh_cmd_rollback()
{
cat << EOF
	echo "$(tput setaf 3;)-----> Creating new symlink from the previous release:$(tput sgr0;) "

	ls -Art "${path_deploy_to}/releases" | sort | tail -n 2 | head -n 1
	ls -Art "${path_deploy_to}/releases" | sort | tail -n 2 | head -n 1 | xargs -I active ln -nfs "${path_deploy_to}/releases/active" "${path_deploy_to}/current"

	echo "$(tput setaf 3;)-----> Deleting current release:$(tput sgr0;) "

	ls -Art "${path_deploy_to}/releases" | sort | tail -n 1
	ls -Art "${path_deploy_to}/releases" | sort | tail -n 1 | xargs -I active rm -rf "${path_deploy_to}/releases/active"

	echo "$(tput setaf 2;)-----> Rollback done$(tput sgr0;)"
EOF
}

ssh_cmd_apply_permissions(){
cat << EOF
	chown -R ${dir_deploy_owner}:${dir_deploy_owner} ${path_deploy_to} &&
	chmod -R g+rx,u+rwx ${path_deploy_to}

	echo "$(tput setaf 3;)-----> Permissions applied$(tput sgr0;)"
EOF
}


# Help - Your friendly help section
usage()
{
cat <<- EOT

  Usage :  $0 [options] [--]

  If using deploy.sh, run the script from the same directory.

  Options:
  --init        Initialize the deploy location
  deploy|-d     Deploy the site
  rollback|-r   Rollback to a previous version of the site
  unlock|-u     Remove lockfile
  help|-h       Display this message

  Directory structure:
  /var/www/ 			# path_deploy_to
   |-  cache/           # dir_deploy_cache - rsync to save bandwidth
   |-  current          # a symlink to the current release in releases/
   |-  deploy.lock      # lock_file - help prevent multiple ongoing deploys
   |-  last_version     # contains the number of the last release
   |-  releases/        # dir_deploy_releases - one subdir per release
       |- 1/
       |- 2/
       |- ...
EOT
}


while [ $1 ]
do
    case $1 in

	  	--init )
	  		ssh_cmd_init | ssh_cmd
	  		exit 0
	  		;;

		deploy|-d )
			get-server-variables &&
			deploy-prompt &&
			deploy-rsync-cache &&
			ssh_cmd_stage | ssh_cmd &&
			ssh_cmd_cleanup | ssh_cmd &&
			ssh_cmd_apply_permissions | ssh_cmd &&
			ssh_cmd_unlock | ssh_cmd &&
			deploy-done
			exit 0
			;;

		rollback|-r )
			ssh_cmd_rollback | ssh_cmd &&
			ssh_cmd_unlock | ssh_cmd
			exit 0

			;;
		unlock|-u )
			ssh_cmd_unlock | ssh_cmd
			exit 0
			;;

		help|-h )
			usage
			exit 0
			;;

		* )
			echo "Option does not exist : $OPTARG"
			usage
			exit 1
			;;
  esac
done
shift $(($OPTIND-1))
