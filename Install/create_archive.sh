#!/bin/bash
list=$@

BASEDIR=$(dirname "$0")
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source <( grep '=' "${SCRIPT_DIR}"/../settings.conf )
#echo rinex_mode=${rinex_mode} list=${list}

if [[ -n "${rinex_mode}" ]]; then
   for file in ${list}; do
      file_extension="${file##*.}"
      if [[ "${file_extension}" != "tag" ]]; then
         #echo ${BASEDIR}/convbin.sh "$(basename ${file})" "${datadir}" "${rinex_mode}"
         ${BASEDIR}/convbin.sh "$(basename ${file})" "${datadir}" "${rinex_mode}"
         echo " "
      fi 
   done
fi

#echo zip -m9 "${datadir}/${archive_name}" ${list}
zip -m9 "${datadir}/${archive_name}" ${list}
