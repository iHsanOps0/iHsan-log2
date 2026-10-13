#!/usr/bin/env bash

set -u


args=("$@"); args_itr=0


die(){ printf '%s: %s\n' "${0##*/}" "$1" >&2; exit "${2:-1}"; }

valid_name(){ [[ -n "${1:-}" && "$1" != *[!A-Za-z0-9_.-]* && "$1" != .* ]]; }

have(){ ((args_itr < ${#args[@]})); }

see(){ have; local ret=$?; [[ -n "${1:-}" ]] && printf -v "$1" '%s' "${args[args_itr]-}"; return $ret; }

get(){ see "${1:-}" && args_itr=$((args_itr + 1)); }

get_all(){ [[ -n "${1:-}" ]] && local -n _get_all_out="$1" && _get_all_out=("${args[@]:args_itr}"); }


source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"/../lib/iHsan-log2.bash

[[ -n "${VAR_DIR:-}" ]] || die "Program bug."


# 1. Resolving operation's configuration, so action, type and config based modifiers

# Config map

declare -a config_map=(

	'set label h HARD 0'

	'set profile ad ADDRESSED 0'
	'set profile c CREATE 0'

	'print profile ad ADDRESSED 0'

	'unset scope ab ABORTED 0'
)

get verb || die "Missing verb."

((${#verb} == 2)) || die "Bad verb $verb : action and type expected."

action="${verb:0:1}"; type_="${verb:1:1}"

case "$action" in
	's') action='set';;
	'u') action='unset';;
	'p') action='print';;
	*) die "Unknown action : $action.";;
esac

case "$type_" in
	'l') type_='label';;
	's') type_='scope';;
	'f') type_='file';;
	'm') type_='message';;
	'p') type_='profile';;
	*) die "Unknown type : $type_.";;
esac

declare -A config

# Base config

while read -r token_action token_type _ token_modifier token_value; do

	[[ "${token_value:-}" == [01] ]] || die "Program bug."

	[[ "$token_action $token_type" == "$action $type_" ]] || continue

	config[$token_modifier]=$token_value 
done < <(printf '%s\n' "${config_map[@]}")

# Profile's config

if [[ -n "${IHSAN_LOG2_PROFILE:-}" ]]; then

	valid_name "$IHSAN_LOG2_PROFILE" || die "Profile name '$IHSAN_LOG2_PROFILE' is incorrect."

	profile="$VAR_DIR/profiles/$IHSAN_LOG2_PROFILE"; 

	[[ -f "$profile" ]] || die "Unknown profile : $IHSAN_LOG2_PROFILE."
	
	while read -r profile_action profile_type profile_modifier profile_value; do

		[[ -n "${profile_action:-}" && ${profile_action:0:1} != '#' ]] || continue 

		[[ "${profile_value:-}" == [01] ]] || die "Bad config : '$profile_value' for '$profile_modifier'."

		[[ "$profile_action $profile_type" == "$action $type_" ]] || continue

		modifier_hit=0; while read -r map_action map_type _ map_modifier _; do
			
			[[ "$profile_action $profile_type $profile_modifier" == "$map_action $map_type $map_modifier" ]] && { modifier_hit=1; break; }
		done < <(printf '%s\n' "${config_map[@]}")

		((modifier_hit)) || die "Bad config : Unrecognized modifier '$profile_modifier'."

		config[$profile_modifier]=$profile_value

	done < "$profile"
fi

# 3. Resolving options, so modifiers(?value, character symbol), labels(character symbol) and files(relative_name)

declare -a labels; declare -a files;

read_modifier_duplet(){

	local action="${1:-}"; shift
	local type_="${1:-}"; shift
	local modifier_duplet="${1:-}"; shift
	local is_nullable="${1:-}"
	local modifier
	local value

	if ((is_nullable)); then

		case "${modifier_duplet:0:1}" in
			'-') modifier_duplet="${modifier_duplet:1}";;
			'n') value=0; modifier_duplet="${modifier_duplet:1}";;
			*) value=1;;
		esac
	else

		case "${modifier_duplet:0:1}" in
			'n') value=0; modifier_duplet="${modifier_duplet:1}";;
			*) value=1;;
		esac
	fi

	case "${#modifier_duplet}" in
		1) modifier=${modifier_duplet:0:1};;
		2) modifier=${modifier_duplet:0:2};;
		*) return 1;;
	esac
	
	while read -r map_action map_type map_modifier_symbol map_modifier _; do

		if [[ "$map_action $map_type $map_modifier_symbol" == "$action $type_ $modifier" ]]; then

			[[ -n "${value:-}" ]] && printf '%s %s' "$map_modifier" "$value" || printf '%s' "$map_modifier"
			
			return 0
		fi
	done < <(printf '%s\n' "${config_map[@]}")

	return 1
}

read_modifier(){

	read -r modifier value < <(read_modifier_duplet "$action" "$type_" "${1:-}"); wait $! || return 1

	config["$modifier"]="$value"
}

read_labels(){

	local argument_labels="$1"

	for ((i=0; i<${#argument_labels}; i++)); do

		local label="${argument_labels:$i:1}"

		valid_name "$label" || die "Bad label : '$label'."
		
		[[ -f "$VAR_DIR/labels/$label" ]] || die "Not a label : $label."

		labels+=("$label")
	done
}

read_files(){
	while local file; see file && [[ "${file:0:1}" != '-' ]]; do

		valid_name "$file" || die "Bad file name : '$file'."

		get; files+=("$file")
	done
}

while true; do

	see arg || break

	case "$arg" in

		'-l'*) get; read_labels "${arg#-l}";;

		'-f') get; read_files;;

		'--') get; break;;

		'-'*) get; read_modifier "${arg#-}" || die "Unknown option : '$arg'; if it was meaned to be an argument, use '--' before to desambiguify.";;

		*) break;;
	esac
done

# 4. Execute the operation (set | unset | print) on a type (label | scope | file | message)

# Lazy initializing the file, writing on his content, adding a write checkpoint

write(){

	local write_type="$1"; shift

	get_all lines
	declare -a labels_lines

	for label in "${labels[@]}"; do

		mapfile -t label_lines < "$VAR_DIR/labels/$label"

		labels_lines+=("${label_lines[@]}")
	done

	message=('' "$@" "${labels_lines[@]}" "${lines[@]}" '')

	((10#${#message[@]})) || return 1
	
	for file in "${files[@]}"; do

		local file_content="$VAR_DIR/files/$file/content" 
		local file_checkpoints="$VAR_DIR/files/$file/checkpoints"

		# Lazy init
		mkdir -p "$VAR_DIR/files/$file/scopes"

		checkpoint_line=0; [[ -f "$file_content" ]] && checkpoint_line=$(( $(wc -l < "$file_content") ))

		printf '%s %s\n' $checkpoint_line "$write_type" >> "$file_checkpoints"

		printf -v prefix '%*s ' $(( $(find "$VAR_DIR/files/$file/scopes" -maxdepth 1 -type f | wc -l) )) ''; prefix="${prefix// /+}"

		sep=' '

		printf '%s\n' "${message[@]/#/$prefix$sep}" >> "$file_content"
	done
}

write_profile(){
	
	local profile="$VAR_DIR/profiles/$1"; shift
	local action="$1"; shift
	local type_="$1"; shift
	local modifier="$1"; shift
	local value="${1:-}"

	[[ -f "$profile" ]] && mapfile -t a_profile < "$profile" || declare -a a_profile

	modifier_hit=0; i=0; while read -r an_action a_type a_modifier _; do
		
		if [[ "$an_action $a_type $a_modifier" == "$action $type_ $modifier" ]]; then

			if [[ "$value" == [01] ]]; then

				a_profile[$i]="$action $type_ $modifier $value"
			else

				unset "a_profile[$i]"
			fi

			modifier_hit=1; break
		fi

		((i++))
	done < <(printf '%s\n' "${a_profile[@]}")

	[[ $modifier_hit -eq 0 && -n $value ]] && a_profile+=("$action $type_ $modifier $value") 

	mkdir -p "$VAR_DIR/profiles"

	printf '%s\n' "${a_profile[@]}" > "$profile"
}

case "$action $type_" in

	'set scope'|'unset scope'|'set message'|'unset file'|'print file') ((${#files[@]})) || die "No file sent.";;&

	'set label')

		get label || die "Label name not sent."

		valid_name "$label" || die "Label name '$label' is not a valid one."

		[[ ${#label} -eq 1 ]] || die "Labels names are only one character sized."
		
		get_all lines

		if [[ ${config[HARD]} -eq 0 ]]; then

				[[ -f "$VAR_DIR/labels/$label" ]] && die "Label '$label' already exists."
		fi
			
		((10#${#lines[@]})) && printf '%s\n' "${lines[@]}" > "$VAR_DIR/labels/$label"
	;;

	'unset label')

		if ((${#labels[@]})); then

			for label in "${labels[@]}"; do

				rm -f "$VAR_DIR/labels/$label"
			done
		else

			for label in "$VAR_DIR/labels"/*; do

				rm -f "$label"
			done
		fi
	;;

	'print label')
		
		if ((${#labels[@]})); then

			for label in "${labels[@]}"; do

				echo "LABEL '$label' :"

				cat "$VAR_DIR/labels/$label"

				echo "END OF LABEL '$label'."
			done
		else
			
			for label in "$VAR_DIR/labels"/*; do

				[[ -f "$label" ]] || continue

				echo "LABEL '$(basename "$label")' :"

				cat "$label"

				echo "END OF LABEL '$(basename "$label")'"
			done
		fi
	;;

	'set scope')

		declare -a prefix_lines=('' '-- Starting... --' '')

		get_all lines

		declare -a labels_lines

		for label in "${labels[@]}"; do

			mapfile -t label_lines < "$VAR_DIR/labels/$label"

			labels_lines+=("${label_lines[@]}")
		done;

		for file in "${files[@]}"; do

			mkdir -p "$VAR_DIR/files/$file/scopes"
		
			printf '%s\n' "${labels_lines[@]}" "${lines[@]}" > "$VAR_DIR/files/$file/scopes/$(( $(find "$VAR_DIR/files/$file/scopes" -maxdepth 1 -type f | wc -l) + 1 ))" 
		done

		write 'scope' "${prefix_lines[@]}"
	;;

	'unset scope')

		get unscopes_count || die "Unscope count not sent."

		[[ "$unscopes_count" =~ ^[0-9]+$ ]] || die "Sent unscope count is not a count."

		((10#$unscopes_count)) || die "Sent unscope count is 0."

		declare -a prefix_lines; [[ "${config[ABORTED]}" -eq 0 ]] && prefix_lines=('' '-- Ended. --' '') || prefix_lines=('' '-- Aborted. --' '')

		for ((i=0; i<10#$unscopes_count; i++)); do

			kept_files=()

			for file in "${files[@]}"; do

				scopes_count=0

				for scope_path in "$VAR_DIR/files/$file/scopes"/*; do

					[[ -f "$scope_path" ]] && scopes_count=$((scopes_count + 1))
				done

				((scopes_count > 0)) && kept_files+=("$file")
			done

			files=(${kept_files[@]+"${kept_files[@]}"})

			((${#files[@]})) || break

			write 'unscope' "${prefix_lines[@]}"

			for file in "${files[@]}"; do

				scopes_count=0

				for scope_path in "$VAR_DIR/files/$file/scopes"/*; do

					[[ -f "$scope_path" ]] && scopes_count=$((scopes_count + 1))
				done

				rm -f "$VAR_DIR/files/$file/scopes/$scopes_count"
			done
		done
	;;

	'unset file')
		
		for file in "${files[@]}"; do

			rm -rf "$VAR_DIR/files/$file"
		done
	;;

	'print file')
		
		for file in "${files[@]}"; do

			echo "FILE '$file' :"

			[[ -f "$VAR_DIR/files/$file/content" ]] && cat "$VAR_DIR/files/$file/content" || echo "- EMPTY -"

			echo "END OF FILE '$file'."
		done
	;;

	'set message') write 'message' || die "Nothing to write.";;

	'set profile')

		if ((config[ADDRESSED])); then
			
			get target_profile || die "No profile sent."

			valid_name "$target_profile" || die "Bad profile name : $target_profile."

			[[ -d "$VAR_DIR/profiles" && -f "$VAR_DIR/profiles/$target_profile" ]] || die "Profile not existing."

		elif ((config[CREATE])); then

			get target_profile || die "No profile name sent."

			valid_name "$target_profile" || die "Bad profile name : $target_profile."

			[[ ! -f "$VAR_DIR/profiles/$target_profile" ]] || die "Profile already exists : $target_profile."
		else
		
			[[ -n ${profile:-} ]] && target_profile="${profile##*/}" || die "No profile bound."
		fi

		get_all modifier_triplets

		((${#modifier_triplets[@]})) || die "No modification sent."

		to_write=()

		while read -r an_action a_type a_modifier_duplet; do

			read -r a_modifier a_value < <(read_modifier_duplet "${an_action:-}" "${a_type:-}" "${a_modifier_duplet:-}" 1); wait $! || die "Unrecognized modifier."

			to_write+=("$an_action $a_type $a_modifier ${a_value:-}")

		done < <(printf '%s\n' "${modifier_triplets[@]}")

		while read -r an_action a_type a_modifier a_value; do

			write_profile "$target_profile" "$an_action" "$a_type" "$a_modifier" "$a_value"

		done < <(printf '%s\n' "${to_write[@]}")
	;;

	'unset profile')
		
		get target_profile || die "Bad args : no target profile sent on profile deletion."

		valid_name "$target_profile" || die "Bad profile name : $target_profile."

		[[ -d "$VAR_DIR/profiles" && -f "$VAR_DIR/profiles/$target_profile" ]] || die "Profile '$target_profile' doesn't exist."

		rm -f "$VAR_DIR/profiles/$target_profile"
	;;

	'print profile')

		if ((config[ADDRESSED])); then

			get target_profile || die "Bad args : no profile sent to an addressed profile printing."

			valid_name "$target_profile" || die "Bad profile name : $target_profile."

			[[ -d "$VAR_DIR/profiles" && -f "$VAR_DIR/profiles/$target_profile" ]] || die "Bad args : profile '$target_profile' doesn't exist."

		elif [[ -n "${profile:-}" ]]; then

			target_profile="${profile##*/}"
		else

			die "Bad config : no profile bound."
		fi

		echo "PROFILE START: $target_profile"

		cat "$VAR_DIR/profiles/$target_profile"

		echo "PROFILE END"
	;;

	*) die "Unrecognized action and type duple : $action, $type_.";;
esac
