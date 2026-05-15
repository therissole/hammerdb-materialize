#!/bin/tclsh
# Container-aware TPCC run/profile script based on HammerDB upstream pg_tprocc_run_profile.tcl

proc env_or_default {name default} {
    if {[info exists ::env($name)] && [string trim $::env($name)] ne ""} {
        return [string trim $::env($name)]
    }
    return $default
}

if {![info exists ::env(TMP)] || [string trim $::env(TMP)] eq ""} {
    set ::env(TMP) "[pwd]/TMP"
    file mkdir $::env(TMP)
    puts "TMP not set, defaulting to $::env(TMP)"
}

set tmpdir $::env(TMP)
puts "SETTING CONFIGURATION"
dbset db pg
dbset bm TPC-C

set profileid [env_or_default PROFILEID 0]
puts "Using PROFILEID = $profileid"

if {![string is integer -strict $profileid]} {
    puts "ERROR: PROFILEID must be an integer, got '$profileid'"
    exit 1
}
if {$profileid < 0 || $profileid == 1} {
    puts "ERROR: PROFILEID must be 0 (single run) or > 1 (profile)."
    exit 1
}

if {$profileid > 1} {
    if {[catch {jobs profileid $profileid} jerr]} {
        puts "ERROR: jobs profileid failed: $jerr"
        exit 1
    }
}

set uaw 0
if {[string tolower [env_or_default UAW 0]] in {"1" "true" "yes" "on"}} {
    set uaw 1
}

giset commandline keepalive_margin 1200
giset timeprofile xt_gather_timeout 1200

diset connection pg_host [env_or_default PGHOST [env_or_default POSTGRES_HOST postgres]]
diset connection pg_port [env_or_default PGPORT [env_or_default POSTGRES_PORT 5432]]
diset connection pg_sslmode [env_or_default PG_SSLMODE prefer]

diset tpcc pg_superuser [env_or_default PG_SUPERUSER [env_or_default POSTGRES_USER postgres]]
diset tpcc pg_superuserpass [env_or_default PG_SUPERUSERPASS [env_or_default POSTGRES_PASSWORD postgres]]
diset tpcc pg_defaultdbase [env_or_default PG_DEFAULTDBASE postgres]
diset tpcc pg_user [env_or_default PG_USER [env_or_default TPCC_USER tpcc]]
diset tpcc pg_pass [env_or_default PG_PASS [env_or_default TPCC_PASS tpcc]]
diset tpcc pg_dbase [env_or_default PG_DBASE [env_or_default POSTGRES_DB tpcc]]
diset tpcc pg_driver timed
diset tpcc pg_rampup [env_or_default TPROC_C_RAMPUP 2]
diset tpcc pg_duration [env_or_default TPROC_C_DURATION 5]
diset tpcc pg_allwarehouse false
if {$uaw || [string tolower [env_or_default TPROC_C_ALLWAREHOUSE false]] in {"1" "true" "yes" "on"}} {
    diset tpcc pg_allwarehouse true
}
diset tpcc pg_timeprofile true
diset tpcc pg_vacuum true

puts "TEST STARTED"
if {$profileid == 0} {
    loadscript
    vuset vu [env_or_default TPROC_C_VU vcpu]
    vuset logtotemp 1
    vucreate
    metstart
    tcstart
    tcstatus
    set jobid [vurun]
    metstop
    tcstop
    vudestroy

    set outfile "$tmpdir/pg_tprocc_profile.$profileid"
    puts "Writing to $outfile"
    set of [open $outfile w]
    puts $of $jobid
    close $of

    puts "TEST COMPLETE"
    exit 0
}

set end_vu [expr {[numberOfCPUs] + 8}]
set vu_list {1}
for {set z 4} {$z <= $end_vu} {incr z 4} {
    lappend vu_list $z
}

metstart
tcstart
foreach z $vu_list {
    loadscript
    vuset vu $z
    vuset logtotemp 1
    vucreate
    metstatus
    tcstatus
    set jobid [vurun]
    vudestroy

    set outfile "$tmpdir/pg_tprocc_profile.$profileid"
    puts "Writing to $outfile"
    set of [open $outfile a]
    puts $of $jobid
    close $of
}
tcstop
metstop
puts "TEST COMPLETE"
