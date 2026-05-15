#!/bin/tclsh
# Container-aware TPCC result script based on HammerDB upstream pg_tprocc_result.tcl

if {![info exists ::env(TMP)] || [string trim $::env(TMP)] eq ""} {
    set ::env(TMP) "[pwd]/TMP"
}

set tmpdir $::env(TMP)
set ::outputfile $tmpdir/pg_tprocc
source ./scripts/tcl/generic/generic_tprocc_result.tcl
