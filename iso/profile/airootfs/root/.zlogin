# fix for screen readers
if grep -Fq 'accessibility=' /proc/cmdline &> /dev/null; then
    setopt SINGLE_LINE_ZLE
fi

~/.automated_script.sh

# Omarchy ppc64le: start the configurator on the first console. It collects the
# answers and then execs p9-install, which does the partitioning -- nothing here
# touches a disk. Ctrl+C inside it aborts to this shell, which is why it is not
# wrapped in a loop: an operator who wants a shell should get one.
# tty1 is the video console; hvc0 is the OPAL serial console, which is what a
# BMC serial-over-LAN session lands on -- archiso's own guard only names tty1,
# so on a POWER box consoled over the BMC the configurator would never start and
# you would get a bare root shell with no indication why. Other VTs stay plain
# shells on purpose: on the video console Alt+F2 is how you get one while the
# configurator holds tty1.
case "$(tty)" in
  /dev/tty1|/dev/hvc0)
    [[ -x ~/p9-configurator ]] && OMARCHY_PATH=/usr/share/omarchy ~/p9-configurator
    ;;
esac
