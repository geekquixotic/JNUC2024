#!/bin/zsh

: << README

██████╗  ██████╗  ██████╗██╗  ██╗███████╗████████╗███╗   ███╗ █████╗ ███╗   ██╗
██╔══██╗██╔═══██╗██╔════╝██║ ██╔╝██╔════╝╚══██╔══╝████╗ ████║██╔══██╗████╗  ██║
██████╔╝██║   ██║██║     █████╔╝ █████╗     ██║   ██╔████╔██║███████║██╔██╗ ██║
██╔══██╗██║   ██║██║     ██╔═██╗ ██╔══╝     ██║   ██║╚██╔╝██║██╔══██║██║╚██╗██║
██║  ██║╚██████╔╝╚██████╗██║  ██╗███████╗   ██║   ██║ ╚═╝ ██║██║  ██║██║ ╚████║
╚═╝  ╚═╝ ╚═════╝  ╚═════╝╚═╝  ╚═╝╚══════╝   ╚═╝   ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝

        Name: Policy Map
 Description: Creates a CSV of every policy, their triggers, actions, and scope
  Created By: Chad Lawson
     License: Copyright (c) 2023, Rocketman Management LLC. All rights reserved.

      Parameter Options
        A number of options can be set with via the command line
        The order does not matter, but they must be written in this format:
           --options=value
           --trueoption
        See the section immediately below starting with CONFIG for the list.

README

declare -A CONFIG=(
	[jamfuser]=''
	[jamfpass]=''
	[jamfurl]=''
	[outfile]='Policy Map.csv'
)

###
### Slothrup Functions
###

### Input Handlers ###

function loadArgs { #79f91#
	## loadArgs "CONFIG" $argv

	## Input
	local hashName=$1  ## The name of the array as a string and NOT the array itself
	shift              ## Now we just deal with the rest

	## Output: NULL

	## Now we make sure the rest is treated as an array regardless whether
	## the OS sent as string or list
	local argString="${argv}"
	local argList=(${(s:|:)argString//\ -/|-})

	## Get a list of keys from the array
	keys=${(Pk)hashName}

	for arg in ${argList}; do

		## If it matches "--*" or "--*=*", parse into key/value or key/true
		case "${arg}" in
			--*=* ) # Key/Value pairs
				key=$(echo "$arg" | sed -E 's|^\-\-([^=]+)\=.*$|\1|g')
				val=$(echo "$arg" | sed -E 's|^\-\-[^=]+\=(.*)$|\1|g')
			;;

			--* ) # Simple flags
				key=$(echo "$arg" | sed -E 's|\-+(.*)|\1|g')
				val="True"
			;;

			*) # Invalid or no match in keys
				key=''
				val=''
		esac

		## If the current key is in the list of valid keys, update the array
		if [[ ${key} && $keys[(Ie)$key] -gt 0 ]]; then
			eval "${hashName}[${key}]='${val}'"
		fi

	done

	return 0 ## All is well
}

function gatherUserInput { #07958#
	## [[ -z ${CONFIG[jamfuser]} || -z ${CONFIG[jamfpass]} ]] && gatherUserInput

	## Input:   NULL
	## Ouptput: NULL - Interacts with user as needed

	## Jamf URL
	if [[ ${CONFIG[jamfurl]} ]]; then
		echo "This computer is enrolled into: ${CONFIG[jamfurl]}"
		echo "Enter a different URL or hit enter."
	fi 

	echo -n "Jamf URL: "
	read userInput
	[[ ${userInput} ]] && CONFIG[jamfurl]=$(echo ${userInput} | sed -E 's/\/{0,1}$//')

	## Check username
	if [[ -z ${CONFIG[jamfuser]} ]]; then
		echo -n "Jamf username: "
		read userInput
		CONFIG[jamfuser]=${userInput}
	fi

	## Check password
	if [[ -z ${CONFIG[jamfpass]} ]]; then
		echo -n "Jamf password: "
		read -s userInput
		CONFIG[jamfpass]=${userInput}
	fi
	echo "" ## Make sure we have a clean newline
}


### Jamf API Functions ###

function getAPIToken { #08613#
	## token=$(getAPIToken "${CONFIG[jamfurl]}" "${CONFIG[basicauth]}")

	## Input
	local jamfURL=$1     # Ex. https://pretendco.jamfcloud.com
	local basicAuth=$2   # Base64 encoded 'user:password' 

	## Output
	local apiToken=''    # Returns token from jamf

	authToken=$(curl -s -f \
		--request POST \
		--url "${jamfURL}/api/v1/auth/token" \
		--header "Accept: application/json" \
		--header "Authorization: Basic ${basicAuth}" \
		2>/dev/null \
	)	
	statusCode=$?
	if [[ ${statusCode} -gt 0 ]]; then
		return 1
	fi

	## Courtesy of Der Flounder
	## Source: https://derflounder.wordpress.com/2021/12/10/obtaining-checking-and-renewing-bearer-tokens-for-the-jamf-pro-api/
	if [[ $(/usr/bin/sw_vers -productVersion | awk -F . '{print $1}') -lt 12 ]]; then
		apiToken=$(/usr/bin/awk -F \" 'NR==2{print $4}' <<< "$authToken" | /usr/bin/xargs)
	else
		apiToken=$(/usr/bin/plutil -extract token raw -o - - <<< "$authToken")
	fi

	echo ${apiToken}
}

function jamfAPIGet { #42330#
	## computerRecord=$(jamfAPIGet "${CONFIG[token]}" "${CONFIG[jamfurl]}/JSSResource/computers/serialnumber/${CONFIG[serial]}")

	## Input
	local jamfToken="$1"         # API token from getAPIToken()
	local jamfResourcePath="$2"  # Ex. https://pretendco.jamfcloud.com/JSSResource/computers

	## Output
	local textOut=''              # XML returned from Jamf
	local httpCode=''             # HTTP status code returned for $? compare

	## Remove double slashes from URL
	jamfResourcePath=$(echo ${jamfResourcePath} | sed -E 's|([^:])(//)|\1/|g')

	## Get the result from Jamf
	result=$(curl -s \
		-H "Authorization: Bearer ${jamfToken}" \
		-H "Accept: text/xml" \
		"${jamfResourcePath}" \
		--write-out "%{http_code}"
	)

	## The last three characters are the HTTP status code
	httpCode=${result: -3} ## Last three
	textOut=${result:0:-3} ## Everything but

	echo "${textOut}"   ## Send back the text
	return ${httpCode}  ## Return the code for $? comparisons
}

function getField { #22cd2#
	## computerName=$(getField "//computer/name/text()" "${computerRecord}")

	## Input
	local needle=$1     # XPath to data - e.g. '//computer/name/text()'
	local haystack=$2   # XML to search for string

	## Output
	local result=''     # Match(es) returned from XPath as string

	## Newer OSs require an operand of '-e'
	osMajor=$(/usr/bin/sw_vers -productVersion | awk -F . '{print $1}')
	[[ "${osMajor}" -ge 11 ]] && op='-e' || op=''

	fields=$(echo "${haystack}" | xmllint -xpath "${needle}" - 2>/dev/null)
	echo "${fields}"
}

function encodeURL { #357be#
	## sanitized=$(encodeURL "T3$t/M!")
	
	## Input
	local plainText="$1" ## Text to sanitize for GET string
	
	## Output
	local safeText=$(echo "${plainText}" | curl -Gso /dev/null -w %{url_effective} --data-urlencode @- "X" | sed -E 's/.*\/\?(.*).../\1/')
	
	echo ${safeText}
}

function getJamfURL { #49b7e#
	## CONFIG[jamfurl]=$(getJamfURL)

	## Input: NULL
	## Output:
	local jamfURL='' ## The URL of the Jamf server in which the computer is enrolled

	## Get the URL from the plist
	jamfURL=$(defaults read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url)

	## Strip off any trailing slash
	jamfURL=$(echo ${jamfURL} | sed -E 's/\/+$//')

	echo "${jamfURL}"
}


### Misc ###

function debug { #33dc0#
	## debug "Loading info from script parameters"
	## Log format: YYYY-mm-dd HH:MM:SS|PID|Message
	## NOTE: Set ${CONFIG[logfile]} to a file and ${CONFIG[debug]} to any true value

	## Input
	local message=$argv                # The text you want saved to the log	
	## Output: NULL

	## Gather log components
	local jamfPID=$$                   # Reserved variable for PID
	local timestamp=$(date +'%F %T')   # YYYY-MM-DD HH:MM:SS

	## If debug is requested, append to logfile
	[[ ${CONFIG[debug]} ]] && echo "${timestamp}|${jamfPID}|${message}" >> ${CONFIG[logfile]}

	## All is well
	return 0
}

###
### Workflow Functions
###

function elementNames {
	local nodePath="$1"
	local xml="$2"
	local glue="$3"

	[[ ${glue} ]] || glue="; "

	local elmentString=''

	nodeElements=$(getField "${nodePath}" "${xml}")
	elementList=(${(f)nodeElements})
	elementString="${(j[||])elementList}"
	elementString="${elementString//||/${glue}}"
	echo "${elementString}"
}

###
### Main
###

## Load the command line arguments into the CONFIG array
loadArgs "CONFIG" ${argv}

## Get for creds and get token
[[ CONFIG[jamfurl] ]] || CONFIG[jamfurl]=$(getJamfURL) ## Guarantees no trailing slash
[[ ! ${CONFIG[jamfuser]} || ! ${CONFIG[jamfpass]} ]] && gatherUserInput
CONFIG[basicauth]=$(echo -n "${CONFIG[jamfuser]}:${CONFIG[jamfpass]}" | base64)
CONFIG[token]=$(getAPIToken "${CONFIG[jamfurl]}" "${CONFIG[basicauth]}")

## These are the fields within the policy object from the API we will display
displayFields=(
	id
	name
	category
	enabled
	trigger_checkin
	trigger_enrollment
	trigger_login
	trigger_network_state
	trigger_self_service
	trigger_other
	frequency
	packages
	scripts
	recon
	scope_targets
	scope_limits
	scope_exclusions
)

## Start the CSV with the header rows based on above
displayRows=()
headerRow=()
for field in ${displayFields}; do
	field=${field//trigger_/}
	field=${field//scope_/}
	headerRow+=("${(C)field//_/ }")
done
headerRow=${(j:",":)headerRow}
displayRows+=("\"${headerRow}\"")

## Get a list of all the policies
policyData=$(jamfAPIGet "${CONFIG[token]}" "${CONFIG[jamfurl]}/JSSResource/policies")
policyIDList=($(getField "//id/text()" "${policyData}"))

## Get each policy in that list and pull the important fields
echo -n "Fetching policies"
for id in ${policyIDList}; do
	policyRecord=$(jamfAPIGet "${CONFIG[token]}" "${CONFIG[jamfurl]}/JSSResource/policies/id/${id}")

	## All the basics
	name=$(getField "//general/name/text()" "${policyRecord}")
	category=$(getField "//general/category/name/text()" "${policyRecord}")
	enabled=$(getField "//general/enabled/text()" "${policyRecord}")
	trigger_checkin=$(getField "//general/trigger_checkin/text()" "${policyRecord}")
	trigger_enrollment=$(getField "//general/trigger_enrollment_complete/text()" "${policyRecord}")
	trigger_login=$(getField "//general/trigger_login/text()" "${policyRecord}")
	trigger_network_state=$(getField "//general/trigger_network_state_changed/text()" "${policyRecord}")
	trigger_startup=$(getField "//general/trigger_startup/text()" "${policyRecord}")
	trigger_other=$(getField "//general/trigger_other/text()" "${policyRecord}")
	trigger_self_service=$(getField "//self_service/use_for_self_service/text()" "${policyRecord}")
	frequency=$(getField "//general/frequency/text()" "${policyRecord}")

	## The actions
	packages=$(elementNames "//package_configuration/packages/package/name/text()" "${policyRecord}")
	scripts=$(elementNames "//scripts/script/name/text()" "${policyRecord}")
	recon=$(getField "//maintenance/recon/text()" "${policyRecord}")
	[[ ${recon} ]] || recon=""

	## Scope 
	if [[ $(getField "//scope/all_computers/text()" "${policyRecord}") == "true" ]]; then
		scope_targets="All Computers"
	else
		scope_targets=()

		computerString=$(elementNames "//scope/computers/computer/name/text()" "${policyRecord}" ", ")
		[[ ${computerString} ]] && scope_targets+=("Computers: ${computerString}")

		groupString=$(elementNames "//scope/computer_groups/computer_group/name/text()" "${policyRecord}" ", ")
		[[ ${groupString} ]] && scope_targets+=("Groups: ${groupString}")

		departmentString=$(elementNames "//scope/departments/department/name/text()" "${policyRecord}" ", ")
		[[ ${departmentString} ]] && scope_targets+=("Departments: ${departmentString}")

		buildingString=$(elementNames "//scope/buildings/building/name/text()" "${policyRecord}" ", ")
		[[ ${buildingString} ]] && scope_targets+=("Groups: ${buildingString}")

		scope_targets=${(j:; :)scope_targets}
	fi

	## Only one line for limitations
	scope_limits=$(elementNames "//scope/limitations/network_segments/network_segment/name/text()" "${policyRecord}" ", ")

	## Now the exclusions
	scope_exclusions=()

	excludedComputers=$(elementNames "//scope/exclusions/computers/computer/name/text()" "${policyRecord}" ", ")
	[[ ${excludedComputers} ]] && scope_exclusions+=("Computers: ${excludedComputers}")

	excludedGroups=$(elementNames "//scope/exclusions/computer_groups/computer_group/name/text()" "${policyRecord}" ", ")
	[[ ${excludedGroups} ]] && scope_exclusions+=("Groups: ${excludedGroups}")

	excludedBuildings=$(elementNames "//scope/exclusions/buildings/building/name/text()" "${policyRecord}" ", ")
	[[ ${excludedBuildings} ]] && scope_exclusions+=("Buildings: ${excludedBuildings}")

	excludedDepartments=$(elementNames "//scope/exclusions/departments/department/name/text()" "${policyRecord}" ", ")
	[[ ${excludedDepartments} ]] && scope_exclusions+=("Departments: ${excludedDepartments}")

	scope_exclusions=${(j:; :)scope_exclusions}

	## Let's make this a CSV
	displayRow=()
	for field in ${displayFields}; do
		displayRow+=("${(P)field}")
		# echo "${(C)field//_/ } = ${(P)field}"
	done
	displayRow=${(j:",":)displayRow}
	displayRows+=("\"${displayRow}\"")
	# echo "\"${displayRow}\""
	# echo "Fetching ${id} - ${name}"
	echo -n "."
done
echo ""

## Write out the CSV
echo "${(j:\n:)displayRows}" > ${CONFIG[outfile]}