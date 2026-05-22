#!/bin/tclsh
# Container-aware TPCC buildschema script based on HammerDB upstream mssqls_tprocc_buildschema.tcl

proc env_or_default {name default} {
    if {[info exists ::env($name)] && [string trim $::env($name)] ne ""} {
        return [string trim $::env($name)]
    }
    return $default
}

puts "SETTING CONFIGURATION"
dbset db mssqls
dbset bm TPC-C

set dbHost [env_or_default MSSQL_HOST mssql]
set dbPort [env_or_default MSSQL_PORT 1433]
set dbUser [env_or_default MSSQL_USER sa]
set dbPassword [env_or_default MSSQL_SA_PASSWORD YourStrong!Passw0rd]
set dbName [env_or_default MSSQL_DB tpcc]
set useBcpRaw [string tolower [env_or_default MSSQL_USE_BCP false]]
set useBcp [expr {$useBcpRaw in {1 true yes y on}}]

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

set vu [numberOfCPUs]
set warehouse [expr {$vu * 5}]
diset tpcc mssqls_count_ware $warehouse
diset tpcc mssqls_num_vu $vu
diset tpcc mssqls_dbase $dbName
diset tpcc mssqls_use_bcp $useBcp

puts "SCHEMA BUILD STARTED"
buildschema
puts "SCHEMA BUILD COMPLETED"
