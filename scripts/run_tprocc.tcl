#!/usr/bin/tclsh
# Запуск нагрузочного теста TPROC-C
# Env: PG_HOST, PG_PORT, VUSERS, RAMPUP, DURATION

puts "SETTING CONFIGURATION"
dbset db pg
dbset bm TPC-C

diset connection pg_host $::env(PG_HOST)
diset connection pg_port $::env(PG_PORT)
diset tpcc pg_superuser postgres
diset tpcc pg_superuserpass postgres
diset tpcc pg_defaultdb postgres
diset tpcc pg_user tpcc
diset tpcc pg_pass tpcc
diset tpcc pg_dbase tpcc
diset tpcc pg_driver timed
diset tpcc pg_rampup $::env(RAMPUP)
diset tpcc pg_duration $::env(DURATION)
diset tpcc pg_allwarehouse true
diset tpcc pg_timeprofile false

loadscript
print dict
vuset logtotemp 1
vuset vu $::env(VUSERS)
vucreate
vurun
runtimer [expr {($::env(RAMPUP) + $::env(DURATION) + 2) * 60}]
vudestroy
puts "TEST COMPLETE"
