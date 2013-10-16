#!/bin/bash

curl http://apt.basho.com/gpg/basho.apt.key | sudo apt-key add -
sudo bash -c "echo deb http://apt.basho.com $(lsb_release -sc) main > /etc/apt/sources.list.d/basho.list"
sudo apt-get update

sudo apt-get install -o Dpkg::Options::="--force-confnew" -q -y riak=1.4.2-1
sudo apt-get install -q -y riak-cs=1.4.1-1
sudo apt-get install -q -y stanchion=1.4.1-1

sudo bash -c "echo '127.0.0.1 cs.example.com' >> /etc/hosts"

sudo cp .travis/riak.app.config /etc/riak/app.config
sudo cp .travis/riak.vm.args /etc/riak/vm.args
sudo cp .travis/riakcs.app.config /etc/riak-cs/app.config
sudo cp .travis/riakcs.vm.args /etc/riak-cs/vm.args
sudo cp .travis/stanchion.app.config /etc/stanchion/app.config
sudo cp .travis/stanchion.vm.args /etc/stanchion/vm.args

sudo service riak start
sudo service riak-cs start
sudo service stanchion start

sleep 4

curl -H 'Content-Type: application/json' -X POST http://localhost:8080/riak-cs/user --data '{"email":"admin@5apps.com", "name":"admin"}' -o cs_admin_credentials.json
cat cs_admin_credentials.json

curl -H 'Content-Type: application/json' -X POST http://localhost:8080/riak-cs/user --data '{"email":"liquorcabinet@5apps.com", "name":"liquor cabinet"}' -o cs_credentials.json
cat cs_credentials.json

echo "\nFinished"
