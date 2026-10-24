@echo off
sc config WSearch start= disabled
net stop WSearch
exit