#!/bin/bash
sudo systemctl start openborhotkey.service

if [[ "$1" == "OpenBor" ]]; then
    file="$2"
    basefile=$(basename -- "$file")
    basefilename=${basefile%.*}
    
    # Clean up old links
    rm -f "/opt/OpenBor/Paks/$basefile"
    ln -s "$2" "/opt/OpenBor/Paks/$basefile"
    
    # Copy the config file
    if [ ! -f "/opt/OpenBor/Saves/${basefilename}.cfg" ]; then
        cp "/opt/OpenBor/Saves/master.cfg" "/opt/OpenBor/Saves/${basefilename}.cfg"
    fi
    
    cd /opt/OpenBor/ || exit 1
    LD_LIBRARY_PATH=. ./OpenBOR
    # Only remove the link file currently in use
    rm -f "/opt/OpenBor/Paks/$basefile"
else
    file="$2"
    basefile=$(basename -- "$file")
    basefilename=${basefile%.*}
    
    rm -f "/opt/OpenBorFF/Paks/$basefile"
    ln -s "$2" "/opt/OpenBorFF/Paks/$basefile"
    
    if [ ! -f "/opt/OpenBorFF/Saves/${basefilename}.cfg" ]; then
        cp "/opt/OpenBorFF/Saves/master.cfg" "/opt/OpenBorFF/Saves/${basefilename}.cfg"
    fi
    
    cd /opt/OpenBorFF/ || exit 1
    LD_LIBRARY_PATH=. ./OpenBOR
    rm -f "/opt/OpenBorFF/Paks/$basefile"
fi

sudo systemctl stop openborhotkey.service
printf "\033c" > /dev/tty1