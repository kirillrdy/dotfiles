set -e
set -x

sudo dnf install -y gcc gcc-c++

cd ~
if ![[ -f go ]]; then
    git clone https://github.com/golang/go.git
fi

cp -av go go1.4
cd go1.4/src
git checkout go1.4.3
./all.bash

cd ~/go/src
./all.bash
echo "export PATH=$HOME/go/bin:$PATH" >> ~/.bashrc
echo "export GOPATH=$HOME" >> ~/.bashrc
