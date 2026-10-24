@echo off
sc config wuauserv start= disabled
sc config bits start= disabled
sc config usosvc start= demand
sc config camsvc start= demand
net stop camsvc
net stop wuauserv
net stop bits
net stop usosvc
exit