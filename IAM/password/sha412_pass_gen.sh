#!/usr/bin/env bash

#if on ubuntu make sure to install... --> apt-get install pwgen
#--> apt install whois
pass=`pwgen --secure --capitalize --numerals --symbols 12 1`

echo $pass | mkpasswd --stdin --method=sha-512; 
echo $pass
