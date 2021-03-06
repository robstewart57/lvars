#!/bin/bash

# A very simple regression test represinting the minimum standard for each checkin.
# You may need to run this script with "--reinstall" as an extra argument.

set -x
set -e

cabal install -fbeta -fdebug -fnewgeneric -fgeneric ./monad-par/monad-par/ \
    ./par-classes/ ./par-collections/ ./lvish/ ./par-transformers/  \
    $*
#   
#   ./lvish-apps/pbbs ./lvish-graph-algorithms/ \
#    --force-reinstalls
