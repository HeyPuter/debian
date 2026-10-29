# Sourced by /root/.bashrc and /etc/skel/.bashrc: what this shell is, said
# once when an interactive shell starts.
case $- in
    *i*)
        printf '%s\n' \
            'Debian, running as wasm32 on gex.' \
            'apt works: apt update once, then apt install <package> downloads and installs it from the network.' \
            ''
        ;;
esac
