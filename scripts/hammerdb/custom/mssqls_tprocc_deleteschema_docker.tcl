#!/bin/tclsh
# Container-aware TPCC deleteschema script based on HammerDB upstream mssqls_tprocc_deleteschema.tcl

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

puts "DROP SCHEMA STARTED"
deleteschema
puts "DROP SCHEMA COMPLETED"
