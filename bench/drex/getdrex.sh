#!/bin/bash
cd "$(dirname "$0")"

echo "Checking if DReX was already installed..."
if [ -d "$" ] ; then
    echo "DReX was already installed. Only building benchmarks."
    ./build_programs.sh
    exit 0
fi
echo "DReX is not installed.  Fetching and installing."

../../dist/build/kexc/kexc compile fix_dep.kex --out fix_dep
wget http://www.seas.upenn.edu/~rmukund/drex/DReX.zip
unzip -o DReX.zip
rm DReX.zip
cd DReX

cat drex-front/pom.xml | ../fix_dep > drex-front/pom_new.xml
mv drex-front/pom_new.xml drex-front/pom.xml

./build

cd ..

./build_programs.sh

ln -fs "$(pwd)/DReX/drex-bench/target/appassembler/bin"
