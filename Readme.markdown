This is a small project I started with the possible objective of
greatly simplifying open source builds on AIX.  It may be very much
like libtool but as of this writing, libtool still suffers greatly on
AIX.

The project is called aixbin and the idea is to put this directly
somewhere like /usr/local and then add /usr/local/aixbin to your path
*before* /bin or /usr/bin so that /usr/local/aixbin/ld is found in
your path before the system's /usr/bin/ld

There are two programs, **ld** and **rl**.  I will call my version of
**ld** **xld** from here out.

**xld** sits in front of **ld** so a typical gcc -o foo foo.c -ldog
-lcharlie will hit **xld** before it finds **ld**.  **xld** scans the
argument list, adds a map file and passes the arguments down to
**ld**.  If **ld** returns without an error, then **xld** pulls the
resultant shared object or executable back apart using rtl_enable,
"fixes" a few things, and then creates a new shared object or
executable.

The items fixed are:

1. Any -blibpath argument is removed.  Any time I have seen an open
source program try to use -blibpath, it fails utterly.  Instead, any
directories in the -blibpath argument except for /usr/lib and /lib are
added as -L arguments to the call to the initial pass of **ld**.

2. When **ld** returns, the map file that was added as an argument is
scanned.  It tells where the libraries that were used were actually
found at.  Using this information, the import file created by
rtl_enable is modified to make as many of the paths to the imported
objects be absolute paths.  The exception is any library that itself
resolved to a local path according to the map file.

The libpath that is created internal to the executable or shared
object is not change yet.  In particular, it may still contain values
like . and .. so that the executable will still execute in the library
that it was created in.

**xld** is used during build.  After the new project has been
installed, **rl** is then be run to relink the executable to further
promote the internal paths to the referenced objects to be absolute
paths.  The way that **rl** works is that it again calls rtl_enable to
create the import, export, and shell script files to regenerate the
object and then edits the import file and shell script file.

After **rl** runs, these items will be fixed:

1. The internal libpath will not have any relative paths in it.  Any
. or .. or ../.. style elements will be removed.

2. Any object that is referenced in the import file by a relative path
name will be searched using the internal libpath.  If exactly one hit
is found, then the new import file will use the absolute path where
the object was found.  If zero or more than one hit is found, then
**rl** will exit with an error.  The intent is to later change this to
get **rl** to pause and prompt the user for guidance or perhaps have
options to help make this part automatic.

This is a work in progress and will grow and change as I discover new
ways that open source can break the linking process that AIX uses.

------------
Copyright 2011, Perry Smith

This file is part of aixbin.

aixbin is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

aixbin is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with aixbin.  If not, see <http://www.gnu.org/licenses/>.
