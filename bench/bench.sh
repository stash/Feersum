#!/bin/bash

# feersum --native eg/app.feersum &
# pid=$!
# sleep 2;
# for i in 1 2 3 4 5; do
#     while [ `netstat -na | grep WAIT | wc -l` -gt 1000 ]; do
#         sleep 1;
#     done
#     echo "=========== Run $i Feersum Native ===========" | tee -a bench.txt
#     ab -n 10000 -c 100 -q 'http://127.0.0.1:5000/' >> bench.txt   
# done
# kill -9 $pid
# pid=0

# for s in Feersum Starman Starlet Twiggy Corona; do
for s in Starman Starlet Twiggy Corona; do
    while [ `netstat -na | grep 5000 | wc -l` -ge 1 ]; do
        echo 'waiting for port...'
        sleep 1;
    done
    plackup -s $s -E deployment eg/app.psgi &
    pid=$!
    sleep 2;
    for i in 1 2 3 4 5; do
        while [ `netstat -na | grep WAIT | wc -l` -gt 1000 ]; do
            sleep 1;
        done
        echo "=========== Run $i $s PSGI ===========" | tee -a bench.txt
        ab -n 10000 -c 100 -q 'http://127.0.0.1:5000/' >> bench.txt   
    done
    kill -9 $pid
    pid=0
done

