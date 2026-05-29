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
set useBcpRaw [string tolower [env_or_default MSSQL_USE_BCP true]]
set useBcp [expr {$useBcpRaw in {1 true yes y on}}]
set useBcpStr [expr {$useBcp ? "true" : "false"}]

# Force TCP so HammerDB uses MSSQL_PORT instead of default SQL Server resolution.
diset connection mssqls_tcp true
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

set vu [env_or_default TPROC_C_VU [numberOfCPUs]]
set warehouse [env_or_default TPROC_C_WAREHOUSES [expr {$vu * 5}]]
set buildVu $vu
if {[string is integer -strict $vu] && [string is integer -strict $warehouse] && $warehouse > 0 && $vu > $warehouse} {
    puts "Configured build VU ($vu) is greater than warehouses ($warehouse); using build VU = $warehouse."
    set buildVu $warehouse
}
diset tpcc mssqls_count_ware $warehouse
diset tpcc mssqls_num_vu $buildVu
diset tpcc mssqls_dbase $dbName
diset tpcc mssqls_use_bcp $useBcpStr

puts "SCHEMA BUILD STARTED"
buildschema
puts "SCHEMA BUILD COMPLETED"
