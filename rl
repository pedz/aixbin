#!/usr/bin/ksh

# Copyright 2011, Perry Smith
#
# This file is part of aixbin.
#
# aixbin is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# aixbin is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with aixbin.  If not, see <http://www.gnu.org/licenses/>.

#
# This script is semi-interactive.  In a good case, it will run
# automatically but if it has doubts, it will pause and ask for help.
# (Note that the "asking for help" may not get implemented on the
# first pass.)
#
# The script is called: rl <file>
# where <file> is an executable or a shared object.  In the future, it
# will be able to dig into an archive as well.
#
# The script does two things.  First, it removes relative paths from
# the internal libpath so . and .. and ../.. get removed.  The logic
# here is that these introduce security risks.
#
# The second thing the script does is it looks at the loader header
# and if there are any dependencies that are not found via absolute
# paths, then it will relink the executable using absolute paths.
# The path choosen is found by walking the internal libpath (sans any
# relative paths) looking for exactly one match.  If zero or more than
# one matches are found, then the script will pause and ask the user
# for help.
#
# By the way, I don't consider myself a ksh script wizard.
#
# Lets see how this goes...
#
# Note that much is stolen from my "ld" command.

# Global args

# debug is true when we are debugging
typeset debug=false

# trace can be set to "set -x" for debugging as well
typeset trace=""

# Record initial PID so logging is consistent.
typeset my_pid=$$

# default file created by ld but is changed by -o option
a_out=a.out

# true if rtllib is in the import file
typeset saw_rtllib=false

# true if we found relative paths to library files
typeset saw_relative_libs=true

# true if libpath has changed
typeset new_libpath=false

# the libpath we will use
typeset libpath=""

# Called with multiple args
function make_log
{
    echo "${my_pid} $@" >> /tmp/rl-log
}

function scan_import_file
{
    typeset import=$( echo *.imp )
    $trace

    if egrep -q '^#!.*rtllib' "${import}" ; then
	saw_rtllib=true
    fi

    # Grep out the #! lines, remove the #!. and #!.. lines, then see
    # if we have any #! lines left that do not start with a /
    if egrep '^#!' "${import}" |
	egrep -v '^#!\.\.?$' |
	egrep -vq '^#!/' ; then
	saw_relative_libs=true
    fi
    make_log "saw_rtllib=${saw_rtllib} saw_relative_libs=${saw_relative_libs}"
}

# Changes /a/b/c/../d/e/f to /a/b/d/e/f
function clean_path
{
    # set -x
    # make_log "clean_path: $1"

    # .. at the front should not get consumed by .. later on
    # the dotdot_index is the index of the last leading dotdot
    typeset -i arg_index=0 result_index=-1 dotdot_index=-1
    typeset arg_array result_array

    # We set IFS to / to split the path into an array
    typeset TIFS="$IFS"
    IFS=/
    set -A arg_array $1

    typeset -i arg_length="${#arg_array[*]}"
    while [[ $arg_index -lt $arg_length ]] ; do
	typeset comp="${arg_array[$arg_index]}"
	# eat the single dots: foo/./dog => foo/dog
	if [[ "$comp" == "." ]] ; then
	    true
	# a dotdot eats the last component except when it would eat
	# another dotdot
	elif [[ "$comp" == ".." && $result_index -gt $dotdot_index ]] ; then
	    unset result_array[$result_index]
	    let "result_index = result_index - 1"
	else
	    let "result_index = result_index + 1"
	    result_array[$result_index]="$comp"
	    if [[ "$comp" == ".." || "$comp" == "" ]] ; then
		let "dotdot_index = dotdot_index + 1"
	    fi
	fi
	let "arg_index = arg_index + 1"
    done
    typeset result="${result_array[*]}"
    IFS="$TIFS"
    if [[ "$result" = "" ]] ; then
	# /a/.. results in "" which needs to be changed to /
	if [[ $result_index -eq 0 ]] ; then
	    result=/
	# a/.. results in "" which needs to be changed to .
	else
	    result=.
	fi
    fi
    # make_log "clean_path result=$result"
    echo "$result"
}

# called with -blibpath:... argument being passed to ld in the
# rtl_enable generated script
function process_libpath
{
    typeset path
    typeset ofs="$IFS"
    typeset result=""
    # let environment's LIBPATH take precedence if it is set
    typeset oldpath="${LIBPATH:-${1}}"
    $trace

    IFS=:
    for path in ${oldpath} ; do
	case "$path" in
	    -blibpath)			# add this back when we return
		;;

	    /*)			 # any path starting with / we append.
		path="$( clean_path "${path}" )"
		if [[ -z "${result}" ]] ; then
		    result="${path}"
		else
		    new_libpath=true
		    result="${result}:${path}"
		fi
		;;

	    *)				# anything else we eat.
		;;
	esac
    done
    IFS="$ofs"
    make_log "process_libpath returning ${result}"
    echo "${result}"
}

# called with the $LD ... line from the script.
function process_shell_line
{
    typeset result=""
    typeset l
    $trace

    echo "${1}" | tr ' ' '\n' | while read l ; do
	case "${l}" in
	    -bnortllib)
		# If we did *not* see rtllib in the import file list,
		# then we go ahead and add this argument, otherwise,
		# we eat it
		if [[ "${saw_nortllib}" = "false" ]]; then
		    result="${result} ${l}"
		fi
		;;

 	    -blibpath:*)
 		libpath="$( process_libpath "${l}" )"
 		result="${result} -blibpath:${libpath}"
 		;;

	    *)
		result="${result} ${l}"
		;;
	esac
    done
    echo "${result}"
}

# called with no args
function process_shell_file
{
    typeset script=$( echo *.sh )
    typeset l
    $trace

    while read l ; do		# for each line
	case "$l" in
	    '$LD '*)
		process_shell_line "${l}"
		;;

	    *)
		echo "${l}"
		;;
	esac
    done < ${script} > tmp		# read from the import file
    mv ${script} ${script}-orig
    mv tmp ${script}
    chmod +x ${script}
}

# Called with one arg: the #!/a/b/libc.a(dog.o) lines from the import
# file.  Usually the lines are relative: #!libc.a(dog.) and we convert
# them to absolute paths like #!/usr/lib/libc.a(dog.o)
function remap_library
{
    typeset arg="${1}"		     # the whole thing
    typeset full_lib="${arg#\#!}"    # remove #! in front
    typeset lib="${full_lib##*/}"    # libc(dog.o)
    typeset base="${lib%%\(*}"
    typeset new_path=""
    typeset ofs="$IFS"
    typeset oh_my_god=false
    typeset path
    $trace

    make_log "remap_library called with ${1}"
    make_log "remap_library libpath=${libpath}"
    IFS=:
    for path in $libpath ; do
	make_log "remap_library looking at ${path}"

	# We cheat here because I think the loader does too.  We
	# search only for a match of the base and do not dig inside to
	# see if the shared object is inside.
	typeset temp="${path}/${base}"
	if [[ -r "${temp}" ]] ; then
	    if [[ -z "${new_path}" ]] ; then
		new_path="${temp}"
	    elif [[ ! "${new_path}" -ef "${temp}" ]] ; then
		make_log "remap_library: dup paths ${new_path} and ${temp}"
		oh_my_god=true
	    fi
	fi
    done

    if [[ "${oh_my_god}" = true ]] ; then
	echo "Found multiple hits for ${lib}" 1>&2
	exit 1
    fi

    if [[ -z "${new_path}" ]] ; then
	echo "Found no hits for ${lib}" 1>&2
	exit 1
    fi

    echo "#!${new_path%/*}/${lib}"
}

# called with no args
function modify_import_file
{
    typeset import=$( echo *.imp )
    typeset skip_whole_lib=false
    typeset l
    $trace

    while read l ; do		# for each line
	case "$l" in
	    "#!."|"#!.."|"#!/*")	# Don't muck with these
		skip_whole_lib=false
		echo "${l}"
		;;
		    
	    "#!"*)
		if [[ "${l}" = "#!"*librtl.a ]] ; then
		    skip_whole_lib=true
		else
		    remap_library "${l}"
		    skip_whole_lib=false
		fi
		;;
		    
	    *)
		if [[ "${skip_whole_lib}" == false ]] ; then
		    echo "${l}"
		fi
		;;
	esac
    done < ${import} > tmp		# read from the import file
    mv ${import} ${import}-orig
    mv tmp ${import}
}

# Called with no args
function call_rtl_enable
{
    $trace

    # Overview:
    #  1: Make a temp directory

    #  2: Copy the new a.out to temp

    #  3: cd to the temp directory

    #  4: call rtl_enable -s a.out

    #  5: We scan the import file to see if there are any relative
    #     paths being used and see if rtllib is being used.  We set
    #     internal variables in both of these cases.

    #  6: scan and edit the script file that is generated.  If all
    #     paths for the libraries are absolute (previous step) and
    #     libpath does not contain any relative paths, we just go
    #     home.  In the process we remove the -bnortllib argument
    #     being passed to ld if step 5 found that it was in the
    #     library.

    #  7: Assuming we get here, we modify the import file.  It appears
    #     as if we must remove the imports from rtllib if we find
    #     any -- ld will add back in a reference to rtllib.  For each
    #     import from an object that we find via a relative path, we
    #     search the libpath we gathered from step 6 to find the
    #     object.  If we find exactly one, we replace the path with
    #     the absolute path we found else we pause and ask for help.

    #  8: execute the script created by rtl_enable

    #  9: move original a.out to the side

    # 10: copy new a.out in its place.
    
    typeset tmp_dir=/tmp/rl.dir.${my_pid}

    (				       # subshell for local trap
	typeset a_out_base="${a_out##*/}"

	# For debugging, you will want to uncomment the rm and comment
	# out the trap so you can see the intermediate results.
	if [[ "${debug}" = true ]] ; then
	    rm -rf /tmp/rl.dir.*
	else
            trap "rm -rf ${tmp_dir}" EXIT
	fi

	mkdir "${tmp_dir}"		# step 1
	cp "${a_out}" "${tmp_dir}"	# step 2
	(				# another subshell to save cwd
	    trap "" EXIT		# don't delete work when subshell exits
	    cd "${tmp_dir}"		# step 3

	    # step 4
	    if ! rtl_enable -s "${a_out_base}" ; then
		exit $?
	    fi

	    # step 5
	    scan_import_file
					# and write to tmp
	    # step 6
	    process_shell_file
	    make_log "call_rtl_enable libpath=${libpath}"
	    
            # step 7
	    if [[ "${saw_rtllib}" = true || "${saw_relative_libs}" = true ]] ; then
		modify_import_file
	    fi

	    # Now do step 8 by executing *.sh
	    # if it errors out, just leave!
	    if ! ./*.sh ; then
		exit $?
	    fi
	    )
	
	mv "${a_out}" "${a_out}.orig"	# step 9
	cp "${tmp_dir}/${a_out_base}.new" "${a_out}" # step 10
	)
}

make_log "Enter with $@"

if [[ "$1" = "-x" ]] ; then
    debug=true
    trace="set -x"
    $trace
    shift
fi

if [[ $# -ne 1 ]] ; then
    echo "Usage: $( basename $0 ) <file>" 1>&2
    exit 1
fi

a_out="${1}"

call_rtl_enable

make_log "Done"
