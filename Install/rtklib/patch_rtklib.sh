#!/bin/bash

BASEDIR=`realpath $(dirname $(readlink -f "$0"))`
ORIGDIR=`pwd`

lastcode=N
exitcode=0

ExitCodeCheck(){
  lastcode=$1
  if [[ $lastcode > $exitcode ]]
  then
     exitcode=${lastcode}
     #echo exitcode=${exitcode}
  fi
}

doPatch(){
  git checkout ${1}
  ExitCodeCheck $?
  if [[ "${2}" != "" ]]; then
     patch -f ${1} ${BASEDIR}/${2}
     ExitCodeCheck $?
  fi
}

if [[ ${1} == "" ]]
then
   echo Usage: ${0} \<RTKLIB Git Directory\>
   echo Patches should be in the same directory as ${0}
   exit 0
fi

cd ${1}
ExitCodeCheck $?
doPatch src/stream.c stream.patch
doPatch src/streamsvr.c streamsvr.patch
doPatch src/rinex.c rinex.patch
doPatch src/rtkpos.c rtkpos.patch
doPatch src/ppp.c ppp.patch
doPatch src/rcv/septentrio.c septentrio.patch
doPatch src/rcv/unicore.c unicore.patch
doPatch app/consapp/str2str/str2str.c str2str.patch
doPatch app/consapp/str2str/gcc/makefile str2str_makefile.patch
doPatch app/consapp/convbin/gcc/makefile convbin_makefile.patch
doPatch app/consapp/rtkrcv/gcc/makefile rtkrcv_makefile.patch

cd app/consapp/str2str/gcc
ExitCodeCheck $?
#make -s clean all
make -s
ExitCodeCheck $?
if [[ ${exitcode} == 0 ]]; then
   echo sudo cp str2str /usr/local/bin
   sudo cp str2str /usr/local/bin
fi

cd ${ORIGDIR}
ExitCodeCheck $?

echo exit ${exitcode}
exit $exitcode
