# Sourced by /root/.bashrc and /etc/skel/.bashrc: what this shell is, said
# once when an interactive shell starts.
case $- in
    *i*)
        printf '%s\n' \
            'This is a real Debian userland, with KDE Plasma, running as wasm32 in your browser on gex.' \
            'apt works: apt install <package> downloads and installs it from the network.' \
            ''
        ;;
esac
