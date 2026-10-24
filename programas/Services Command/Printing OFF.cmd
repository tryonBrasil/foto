@echo off
sc config spooler start= disabled
net stop spooler
exit