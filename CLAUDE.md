# Objetive
* We need to implement a similar solution to https://github.com/ciroiriarte/nic-xray
* Perspective changes to the switch side
* Proper documentation of cabling and network port configuration is desired.
* Although LibreNMS is recommended for day to day operations for live diagrams, we need a "one shot" snapshot for implementations documentation and troubleshooting.

# Requirements
* Information collection should be executed via SNMP
* First supported platform should be JunOS on QFX switches
* Logic should allow inclusion of additional platforms (Arista, Cumulus, Cisco ACI, etc)
* The user can specify N switches to collect data from. N >=1
* SNMP v2c and 3 should be supported.
* Authentication data should be acceptable via config file, option in the command line or variables.
* All the known output formats should be supported

# Way of work
* The procedure should be written in BASH, features should be exhasted before including more dependencies.
* Documentation should always be in-sync

# Repository
* A new git repo should be built in this directory
* Remote repo should be created at https://github.com/ciroiriarte/switch-xray
