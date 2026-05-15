#!/bin/tclsh
# Container-aware TPCC buildschema script based on HammerDB upstream pg_tprocc_buildschema.tcl

proc env_or_default {name default} {
    if {[info exists ::env($name)] && [string trim $::env($name)] ne ""} {
        return [string trim $::env($name)]
    }
    return $default
}

puts "SETTING CONFIGURATION"
dbset db pg
dbset bm TPC-C

diset connection pg_host [env_or_default PGHOST [env_or_default POSTGRES_HOST postgres]]
diset connection pg_port [env_or_default PGPORT [env_or_default POSTGRES_PORT 5432]]
diset connection pg_sslmode [env_or_default PG_SSLMODE prefer]

set vu [env_or_default TPROC_C_VU [numberOfCPUs]]
set warehouse [env_or_default TPROC_C_WAREHOUSES [expr {$vu * 5}]]

diset tpcc pg_count_ware $warehouse
diset tpcc pg_num_vu $vu
diset tpcc pg_superuser [env_or_default PG_SUPERUSER [env_or_default POSTGRES_USER postgres]]
diset tpcc pg_superuserpass [env_or_default PG_SUPERUSERPASS [env_or_default POSTGRES_PASSWORD postgres]]
diset tpcc pg_defaultdbase [env_or_default PG_DEFAULTDBASE postgres]
diset tpcc pg_user [env_or_default PG_USER [env_or_default TPCC_USER tpcc]]
diset tpcc pg_pass [env_or_default PG_PASS [env_or_default TPCC_PASS tpcc]]
diset tpcc pg_dbase [env_or_default PG_DBASE [env_or_default POSTGRES_DB tpcc]]
diset tpcc pg_tspace pg_default
diset tpcc pg_storedprocs true

if {$warehouse >= 200} {
    diset tpcc pg_partition true
} else {
    diset tpcc pg_partition false
}

puts "SCHEMA BUILD STARTED"
buildschema
puts "SCHEMA BUILD COMPLETED"
