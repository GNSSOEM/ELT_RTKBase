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
   echo Usage: ${0} \<RTKBASE Git Directory\>
   echo Patches should be in the same directory as ${0}
   exit 0
fi

cd ${1}
ExitCodeCheck $?
doPatch tools/install.sh  rtkbase_install_sh.patch 
doPatch tools/create_release.sh  create_release_sh.patch
#doPatch web_app/requirements.txt  requirements_txt.patch

cd tools
./create_release.sh --bundled
ExitCodeCheck $?

cd ${ORIGDIR}
ExitCodeCheck $?

echo exit ${exitcode}
exit $exitcode
