#!/usr/bin/tclsh
# Построение схемы TPROC-C для PostgreSQL
# Параметры через env: PG_HOST, PG_PORT, WAREHOUSES, NUM_VU

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
diset tpcc pg_count_ware $::env(WAREHOUSES)
diset tpcc pg_num_vu $::env(NUM_VU)
diset tpcc pg_partition false
diset tpcc pg_superuser_pass postgres

print dict
buildschema
waittocomplete
puts "SCHEMA BUILD COMPLETE"
