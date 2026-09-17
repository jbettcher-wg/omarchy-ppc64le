# archiso sets root's login shell to /usr/bin/bash (see airootfs/etc/passwd),
# so .zlogin -- which only zsh reads -- never runs. That is why the configurator
# did not start on the first real boot and you got a bare root shell instead.
# Both files carry the same guard so it works whichever shell is in play.

[[ -f ~/.automated_script.sh ]] && ~/.automated_script.sh

# tty1 is the video console; hvc0 is the OPAL serial console a BMC session
# lands on. Other VTs stay plain shells on purpose -- Alt+F2 is how you get one
# while the configurator holds tty1.
case "$(tty)" in
  /dev/tty1|/dev/hvc0)
    [[ -x ~/omp-configurator ]] && OMARCHY_PATH=/usr/share/omarchy ~/omp-configurator
    ;;
esac
