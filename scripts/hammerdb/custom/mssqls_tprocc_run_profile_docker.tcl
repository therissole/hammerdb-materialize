#!/bin/tclsh
# Container-aware TPCC timed workload script based on HammerDB upstream mssqls_tprocc_run.tcl

proc env_or_default {name default} {
    if {[info exists ::env($name)] && [string trim $::env($name)] ne ""} {
        return [string trim $::env($name)]
    }
    return $default
}

proc env_is_true {name default} {
    if {![info exists ::env($name)] || [string trim $::env($name)] eq ""} {
        return $default
    }
    set normalized [string tolower [string trim $::env($name)]]
    return [expr {$normalized in {1 true yes on}}]
}

if {![info exists ::env(TMP)] || [string trim $::env(TMP)] eq ""} {
    set ::env(TMP) "[pwd]/TMP"
    file mkdir $::env(TMP)
    puts "TMP not set, defaulting to $::env(TMP)"
}

set tmpdir $::env(TMP)
puts "SETTING CONFIGURATION"
dbset db mssqls
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

giset commandline keepalive_margin 1200
giset timeprofile xt_gather_timeout 1200

set dbHost [env_or_default MSSQL_HOST mssql]
set dbPort [env_or_default MSSQL_PORT 1433]
set dbUser [env_or_default MSSQL_USER sa]
set dbPassword [env_or_default MSSQL_SA_PASSWORD YourStrong!Passw0rd]
set dbName [env_or_default MSSQL_DB tpcc]

# HammerDB uses the linux_* settings inside the container.
diset connection mssqls_tcp false
diset connection mssqls_port $dbPort
diset connection mssqls_azure false
diset connection mssqls_encrypt_connection true
diset connection mssqls_trust_server_cert true
diset connection mssqls_authentication sql
diset connection mssqls_server $dbHost
diset connection mssqls_linux_server $dbHost
diset connection mssqls_uid $dbUser
diset connection mssqls_pass $dbPassword
diset connection mssqls_linux_authent sql
diset connection mssqls_linux_odbc {ODBC Driver 18 for SQL Server}

diset tpcc mssqls_dbase $dbName
diset tpcc mssqls_driver timed
diset tpcc mssqls_total_iterations 10000000
diset tpcc mssqls_rampup [env_or_default TPROC_C_RAMPUP 2]
diset tpcc mssqls_duration [env_or_default TPROC_C_DURATION 5]
diset tpcc mssqls_allwarehouse [expr {[env_is_true TPROC_C_ALLWAREHOUSE true] ? "true" : "false"}]
diset tpcc mssqls_timeprofile true
diset tpcc mssqls_checkpoint false

puts "TEST STARTED"
if {$profileid == 0} {
    loadscript
    vuset vu [env_or_default TPROC_C_VU vcpu]
    vucreate
    tcstart
    tcstatus
    set jobid [vurun]
    tcstop
    vudestroy

    set outfile "$tmpdir/mssqls_tprocc_profile.$profileid"
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

tcstart
foreach z $vu_list {
    loadscript
    vuset vu $z
    vucreate
    tcstatus
    set jobid [vurun]
    vudestroy

    set outfile "$tmpdir/mssqls_tprocc_profile.$profileid"
    set of [open $outfile a]
    puts $of $jobid
    close $of
}
tcstop
puts "TEST COMPLETE"
