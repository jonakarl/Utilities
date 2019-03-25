#!/bin/bash

if [ $# -ne 2 ]; then
    echo "Usage: $0 location prefix" >&2
    exit 1
fi

location="$1"
prefix="$2"

needindex=1
index=0

while [ $needindex -eq 1 ]
do
        if [ ! -e $location/$prefix$index ]; then
                needindex=0
                echo "$index"
        else
                (( index++ ))
        fi
done