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
# This was started on Jan. 28, 2011.
#
# This is a front end for AIX's ld to fix most of the common mistakes
# that open software and inparticular libtool seem to create and it
# also helps make the paths to the shared libraries absolute which
# helps prevent them from blowing up when LIBPATH is set.
#
# Usage: put this in your path somewhere in front of /usr/bin so that
# it gets called before the real ld gets called.  One use I do is put
# it in an out of the way place like /usr/local/xbin/ld and then
# prepend /usr/local/xbin to my path before starting any open source
# builds.
#

# Global Vars:
LD=/usr/bin/ld

# Index of next argument to add
typeset -i new_arg_index=0

# the path of the loadmap
load_map=""
delete_load_map=false

# default file created by ld but is changed by -o option
a_out=a.out

# (ld): lib xxxxx lines from the load map file.
typeset lib_path_array

# Record initial PID so logging is consistent.
typeset my_pid=$$

# Flag used while processing arguments
typeset saw_o_option=false

# Flags seen while processing ld arguments which influence the final
# link.
typeset saw_32_option=false
typeset saw_64_option=false
typeset saw_autoexp_option=false
typeset saw_dynamic_option=false
typeset saw_ernotok_option=false
typeset saw_erok_option=false
typeset saw_noautoexp_option=false
typeset saw_nortl_option=false
typeset saw_nortllib_option=false
typeset saw_nosymbolic_option=false
typeset saw_rtl_option=false
typeset saw_rtllib_option=false
typeset saw_static_option=false
typeset saw_symbolic_option=false

# Functions

# Called with one arg: the argument to add to the list of arguments to
# pass to the real ld command.
function add_arg
{
    new_args[$new_arg_index]="$1"
    (( new_arg_index+=1 ))
}

# Called with multiple args
function make_log
{
    echo "${my_pid} $@" >> /tmp/ld-log
}

# Called with on arg: the -blibpath:p1:p2:p3 option
function process_libpath_option
{
    typeset path ofs

    ofs="$IFS"
    IFS=:
    for path in $1 ; do
	case "$path" in
	    -blibpath|/lib|/usr/lib) # eat these
		;;

	    *)				# default is to add -L
		add_arg "-L"
		add_arg "$path"
		;;
	esac
    done
    IFS="$ofs"
}

# Called with one arg: the -bloadmap:foo option
function process_loadmap_option
{
    typeset junk path

    echo "$1" | IFS=: read junk path
    load_map="$path"
    add_arg "$1"
}

# Called with no args
function call_ld
{
    # If the command line does not already create a load map, we add
    # that argument and also set a trap so it is deleted on exit.
    if [[ -z "${load_map}" ]] ; then
	load_map=/tmp/ld.map.${my_pid}

	# For debugging, you will want to uncomment the rm and comment
	# out the trap so you can see the intermediate results.
	# rm -f /tmp/ld.map.*
	trap "rm -f ${load_map}" EXIT

	add_arg "-bl:${load_map}"
    fi

    make_log "Calling ld with: ${new_args[@]}" 
    # Call ld and just leave if it fails.
    if ! "${LD}" "${new_args[@]}" ; then
	exit $?
    fi

    
}

# Called with no args
function process_loadmap
{
    typeset dum0 dum1 path tmp
    typeset -i lib_index=0

    fgrep '(ld): lib ' "${load_map}" | while read dum0 dum1 path ; do
	lib_path_array[${lib_index}]="${path}"
	(( lib_index+=1 ))
    done
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

    # echo "arg=${arg}"   1>&2
    for path in "${lib_path_array[@]}" ; do
	path_base="${path##*/}"
	if [[ "${path_base}" = "${base}" ]] ; then
	    # echo "matching path_base=${path_base}" 1>&2
	    # put into new import file
	    # if path is abolute, make library absolute else make
	    # library have not path
	    if [[ "${path}" = /* ]] ; then
		echo "#!${path%/*}/${lib}"
	    else
		echo "#!${lib}"
	    fi
	    return;
	fi
    done

    # Didn't find match so just keep it... does this happen?
    echo "${arg}"
}

# rtl_enable recreates an import file whose name is the input filename
# with the "extension" removed.  So, if the input file is
# dog.hopper.com the import file will be called dog.hopper.imp.  But I
# don't want to try and second guess this so I just use *.imp.  I do
# the same for the export *.exp and shell script *.sh
function process_import_file
{
    typeset import=$( echo *.imp )
    typeset skip_whole_lib=false
    typeset l

    while read l ; do		# for each line
	case "$l" in
	    "#!."|"#!..")	# Don't muck with these
		saw_rtllib_option=true
		saw_nortllib_option=false
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

function process_shell_line
{
    typeset result=""
    typeset l

    echo "${1}" | tr ' ' '\n' | while read l ; do
	case "${l}" in
	    -bnortllib)
		if [[ "${saw_nortllib_option}" = "true" ]]; then
		    result="${result} ${l}"
		fi
		;;

	    -bnosymbolic)
		if [[ "${saw_nosymbolic_option}" = "true" ]]; then
		    result="${result} ${l}"
		fi
		;;

	    -bnoautoexp)
		if [[ "${saw_noautoexp_option}" = "true" ]]; then
		    result="${result} ${l}"
		fi
		;;

# Lets not do this yet.
# 	    -blibpath:*)
# 		result="${result} $(process_libpath_a_second_time "${l}")"
# 		;;

	    *)
		result="${result} ${l}"
		;;
	esac
    done
    echo "${result}"
}

function process_shell_file
{
    typeset script=$( echo *.sh )
    typeset l

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

# Called with no args
function call_rtl_enable
{
    # Overview:
    #  1: Make a temp directory

    #  2: Copy the new a.out to temp

    #  3: cd to the temp directory

    #  4: call rtl_enable -s a.out

    #  5: edit the import file and replace the short names like
    #     libgcc_s with a full path.

    #  6: edit the script that is generated based upon various ld
    #     options passed in.  For example, the script always specifies
    #     the erok, rtl, nortllib, nosymbolic, and noautoexp options.
    #     In each of these, if the original ld options did not include
    #     them, we strip them out of the shell script.

    #  7: execute the script created by rtl_enable

    #  8: move original a.out to the side

    #  9: copy new a.out in its place.
    
    typeset tmp_dir=/tmp/ld.dir.${my_pid}

    (				       # subshell for local trap
	typeset a_out_base="${a_out##*/}"

	# For debugging, you will want to uncomment the rm and comment
	# out the trap so you can see the intermediate results.
	# rm -rf /tmp/ld.dir.*
        trap "rm -rf ${tmp_dir}" EXIT

	mkdir "${tmp_dir}"		# step 1
	cp "${a_out}" "${tmp_dir}"	# step 2
	(				# another subshell to save cwd
	    trap "" EXIT
	    cd "${tmp_dir}"		# step 3

	    # step 4
	    
	    if ! rtl_enable -s "${a_out_base}" ; then
		exit $?
	    fi

	    # step 5
	    process_import_file
					# and write to tmp
	    # step 6
	    process_shell_file

	    # Now do step 6 by executing *.sh
	    # if it errors out, just leave!
	    if ! ./*.sh ; then
		exit $?
	    fi
	    )
	
	mv "${a_out}" "${a_out}.orig"	# step 8
	cp "${tmp_dir}/${a_out_base}.new" "${a_out}" # step 9
	)
}

# main body

make_log "Starting at $( date )"
make_log "Called with: $@"
trap "make_log Done" EXIT

(
# Process each argument to ld
for arg in "$@" ; do
    if [[ "${saw_o_option}" = true ]] ; then
	a_out="${arg}"
	make_log "Outfile: ${a_out}"
	saw_o_option=false
	add_arg "${arg}"
    else
	case "${arg}" in
	    -G)
		saw_erok_option=true
		saw_rtl_option=true
		saw_nortllib_option=true
		saw_nosymbolic_option=true
		saw_noautoexp_option=true

		saw_ernotok_option=false
		saw_nortl_option=false
		saw_rtllib_option=false
		saw_symbolic_option=false
		saw_autoexp_option=false

		add_arg "${arg}"
		;;

	    -o)				# process the -o option
		saw_o_option=true	# set flag to process it on
		add_arg "${arg}"	# next loop
		;;
	    
	    -o*)			# -ofoo smashed together
		a_out="${arg#-o}"
		make_log "Outfile: ${a_out}"
		add_arg "${arg}"
		;;

	    -berok)
		saw_erok_option=true
		saw_ernotok_option=false
		add_arg "${arg}"
		;;
		
	    -bernotok)
		saw_ernotok_option=true
		saw_erok_option=false
		add_arg "${arg}"
		;;
		
	    -b32)
		saw_32_option=true
		saw_64_option=false
		add_arg "${arg}"
		;;

	    -b64)
		saw_64_option=true
		saw_32_option=false
		add_arg "${arg}"
		;;

	    -bdynamic)
		saw_dynamic_option=true
		saw_static_option=false
		add_arg "${arg}"
		;;

	    -blibpath:*)		# process the libpath option
		process_libpath_option "${arg}"
		;;
	    
	    -bl:*|-bloadmap:*)	    	# process load map option (2 forms)
		process_loadmap_option "${arg}"
		;;
	    
	    -bautoexp)
		saw_autoexp_option=true
		saw_noautoexp_option=false
		add_arg "${arg}"
		;;

	    -brtllib)
		saw_rtllib_option=true
		saw_nortllib_option=false
		add_arg "${arg}"
		;;

	    -bsymbolic)
		saw_symbolic_option=true
		saw_nosymbolic_option=false
		add_arg "${arg}"
		;;

	    -brtl)
		saw_rtl_option=true
		saw_nortl_option=false
		add_arg "${arg}"
		;;
	    
	    -bnoautoexp)
		saw_noautoexp_option=true
		saw_autoexp_option=false
		add_arg "${arg}"
		;;

	    -bnortllib)
		saw_nortllib_option=true
		saw_rtllib_option=false
		add_arg "${arg}"
		;;

	    -bnosymbolic)
		saw_nosymbolic_option=true
		saw_symbolic_option=false
		add_arg "${arg}"
		;;

	    -bnortl)
		saw_nortl_option=true
		saw_rtl_option=false
		add_arg "${arg}"
		;;

	    -bstatic)
		saw_static_option=true
		saw_dynamic_option=false
		add_arg "${arg}"
		;;

	    *)				# default is to pass on the argument
		add_arg "${arg}"
		;;
	esac
    fi
done

# Then call ld
call_ld

# Prcess the map file and create a mapping between the base libraries
# and their full path
process_loadmap

# So, now we pull apart what ld just created and put it back together
# better
call_rtl_enable
)
